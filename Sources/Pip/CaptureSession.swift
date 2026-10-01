import AppKit
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

@MainActor
final class CaptureSession {
  var onStateChange: ((CaptureState) -> Void)?
  /// Fired once per source when the captured window disappears. The session
  /// has already stopped the stream and published
  /// `.stopped(capture.sourceClosed)` when this runs.
  var onSourceWindowClosed: (() -> Void)?

  /// Capture rate applied to every stream of this session; changes apply live.
  private(set) var frameRate: FrameRate = .fps30
  /// Normalized region of the source window (0...1, top-left origin, source
  /// orientation). `nil` captures the whole window. Every new source starts
  /// uncropped because the region is meaningless for a different window. A
  /// region the stream rejects reverts to the last applied one, so this always
  /// describes what is captured once updates settle.
  private(set) var crop: CGRect?
  /// Window behind the current stream; `nil` while no stream exists.
  private(set) var sourceWindowID: CGWindowID?

  /// `SCContentSharingPicker.shared` is process-wide while sessions are
  /// per-PiP: the shared configuration is applied once, and `isActive` stays
  /// on while at least one session holds an activation (see
  /// `updatePickerActivation()`).
  private static var pickerConfigured = false
  private static var pickerActivationCount = 0
  /// The only session allowed to present the picker and to consume picker
  /// events that carry no stream. Held from `present` until the picker
  /// reports cancel, update, or start failure (see `pickerPresentation`).
  private static weak var presentingSession: CaptureSession?
  private static let sourcePollInterval: Duration = .seconds(2)
  private static let sourceCloseGracePeriod: Duration = .seconds(1)
  /// Crops narrower or shorter than this fraction of the window are treated
  /// as accidental and ignored.
  private static let minimumCropFraction: CGFloat = 0.01

  private let onFrame: @Sendable (CaptureFrame) -> Void
  private let onReset: @Sendable (UInt64) -> Void
  private nonisolated(unsafe) let picker: SCContentSharingPicker
  private let sampleQueue: DispatchQueue
  private let frameGate = FrameGate()
  private var state: CaptureState = .idle
  private var generation: UInt64 = 0
  private var operationID: UInt64 = 0
  /// Every stream change also refreshes `sourceWindowID`, the source-window
  /// monitor, and this session's picker activation.
  private var currentStream: StreamContext? {
    didSet {
      guard currentStream !== oldValue else { return }
      sourceWindowID = currentStream?.sourceWindowID
      restartSourceMonitor()
      updatePickerActivation()
    }
  }
  private var pendingSource: PendingSource?
  private var replacementTask: Task<Void, Never>?
  private var stopTask: Task<Void, Never>?
  private var intentionalStops = Set<ObjectIdentifier>()
  private nonisolated(unsafe) var workspaceObserverTokens: [NSObjectProtocol] = []
  /// The user is choosing a source in the picker this session presented;
  /// implies `pickerPresentation`, which can outlive it.
  private var selectionInProgress = false
  /// Set while the picker this session presented may still be on screen. A
  /// source chosen from the in-app list ends the selection but not the sheet,
  /// so this session stays the presenting session until the picker reports
  /// back for it.
  private var pickerPresentation: PickerPresentation? {
    didSet {
      if pickerPresentation != nil {
        Self.presentingSession = self
      } else if Self.presentingSession === self {
        Self.presentingSession = nil
      }
    }
  }
  private var stateBeforeSelection: CaptureState?
  private var pickerObserver: PickerObserverBridge?
  private var holdsPickerActivation = false
  private var workspaceInactive = false
  private var streamInactive = false
  private var frameSuspended = false
  private var frameSuspensionRevision: UInt64?
  private let workspaceTransitionBox = TransitionBox()
  private var lastWorkspaceTransitionID: UInt64 = 0
  private var userStopped = false
  private var selectionRequestedAfterStop = false
  private var startRequestedAfterStop: PendingStart?
  private var targetOutputSize: CGSize?
  private var configurationUpdateTask: Task<Void, Never>?
  private var sourceMonitorTask: Task<Void, Never>?

  init(
    onFrame: @escaping @Sendable (CaptureFrame) -> Void,
    onReset: @escaping @Sendable (UInt64) -> Void
  ) {
    self.onFrame = onFrame
    self.onReset = onReset
    self.picker = .shared
    self.sampleQueue = DispatchQueue(
      label: "dev.local.pip.capture.samples",
      qos: .userInitiated
    )
    self.pickerObserver = nil
    self.pickerObserver = PickerObserverBridge(
      onCancel: { [weak self] event in
        Task { @MainActor [weak self] in
          self?.handlePickerCancel(event)
        }
      },
      onUpdate: { [weak self] update in
        Task { @MainActor [weak self] in
          self?.handlePickerUpdate(update)
        }
      },
      onStartFailure: { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.handlePickerStartFailure()
        }
      }
    )

    configurePicker()
    installWorkspaceObservers()
  }

  func chooseWindow() {
    if stopTask != nil {
      startRequestedAfterStop = nil
      selectionRequestedAfterStop = true
      return
    }
    guard !selectionInProgress else { return }
    // The shared picker shows one selection at a time; another session's
    // open picker wins and this request is dropped.
    if let presenter = Self.presentingSession, presenter !== self { return }

    userStopped = false
    selectionInProgress = true
    stateBeforeSelection = state
    // Re-presenting over this session's own still-open sheet just brings it
    // back for the current stream.
    let stream = currentStream?.stream
    pickerPresentation = PickerPresentation(stream: stream)
    publish(.selecting)
    updatePickerActivation()

    if let stream {
      picker.present(for: stream, using: .window)
    } else {
      picker.present(using: .window)
    }
  }

  /// Starts capturing `filter` (or replaces the current source) without the
  /// system picker, through the same pipeline as a picker selection. Any
  /// picker selection this session has open is ended first.
  func start(filter: SCContentFilter, title: String) {
    if stopTask != nil {
      selectionRequestedAfterStop = false
      startRequestedAfterStop = PendingStart(filter: filter, title: title)
      return
    }

    userStopped = false
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    acceptSource(
      filter: filter,
      title: trimmedTitle.isEmpty ? L10n.string("capture.untitledWindow") : trimmedTitle
    )
  }

  func stop() async {
    if let stopTask {
      // A later stop supersedes a restart queued behind the in-flight one.
      startRequestedAfterStop = nil
      selectionRequestedAfterStop = false
      await stopTask.value
      return
    }

    let task: Task<Void, Never> = Task { @MainActor [weak self] in
      guard let self else { return }
      await self.performStop()
    }
    stopTask = task
    await task.value
  }

  private func performStop() async {
    userStopped = true
    // An open sheet keeps `pickerPresentation` (and with it the presenting
    // slot and a picker activation) until the picker reports back; its
    // choice is then dropped because the session is stopped.
    selectionInProgress = false
    stateBeforeSelection = nil
    pendingSource = nil
    operationID = nextOperationID()
    workspaceInactive = false
    streamInactive = false
    frameSuspended = false
    frameSuspensionRevision = nil

    let stoppedGeneration = advanceGeneration()
    frameGate.pause(stoppedGeneration)

    if let replacementTask {
      await replacementTask.value
    }

    if let context = currentStream {
      await stop(context, intentionally: true)
    }
    currentStream = nil
    // A queued start() publishes `.starting` itself; an intermediate `.stopped`
    // would make observers drop state tied to that restart.
    if startRequestedAfterStop == nil {
      publish(.stopped(L10n.string("capture.stopped")))
    }
    stopTask = nil
    updatePickerActivation()

    if let start = startRequestedAfterStop {
      startRequestedAfterStop = nil
      selectionRequestedAfterStop = false
      self.start(filter: start.filter, title: start.title)
    } else if selectionRequestedAfterStop {
      selectionRequestedAfterStop = false
      chooseWindow()
    }
  }

  /// Sets the maximum capture output size in pixels. The stream output fits
  /// inside this size without exceeding the source window's native pixels.
  func updateOutputSize(_ pixelSize: CGSize) {
    guard pixelSize.width.isFinite, pixelSize.height.isFinite,
      pixelSize.width > 0, pixelSize.height > 0
    else { return }
    let target = CGSize(
      width: max(pixelSize.width.rounded(), 1),
      height: max(pixelSize.height.rounded(), 1)
    )
    guard target != targetOutputSize else { return }
    targetOutputSize = target
    applyConfigurationIfNeeded()
  }

  /// Sets the capture rate; a running stream is reconfigured without restart.
  func setFrameRate(_ rate: FrameRate) {
    guard rate != frameRate else { return }
    frameRate = rate
    applyConfigurationIfNeeded()
  }

  /// Sets the captured region as a normalized, top-left-origin rect of the
  /// source window. The rect is clamped to 0...1; `nil`, the whole window, or
  /// a region under `minimumCropFraction` on either axis clears the crop.
  /// A running stream is reconfigured without restart.
  func setCrop(_ normalized: CGRect?) {
    let sanitized = normalized.flatMap(Self.sanitizedCrop)
    guard sanitized != crop else { return }
    crop = sanitized
    // Map the region onto the window as it is now, not as of the last poll.
    if let context = currentStream,
      let windowID = context.sourceWindowID,
      let windowSize = Self.liveWindowSize(of: windowID)
    {
      context.windowSize = windowSize
    }
    applyConfigurationIfNeeded()
  }

  private func applyConfigurationIfNeeded() {
    guard configurationUpdateTask == nil,
      let context = currentStream,
      context.started,
      !context.stopSignaled,
      streamSettings(for: context) != context.appliedSettings
    else { return }

    configurationUpdateTask = Task { @MainActor [weak self] in
      guard let self else { return }
      await self.drainConfigurationUpdates()
    }
  }

  /// Applies the latest settings (output size, frame rate, crop, window size)
  /// to the current stream, one update at a time. Changes that arrive while an
  /// update is in flight are picked up by the next loop iteration; a stopping
  /// or not-yet-started stream ends the loop. A failed update is not retried
  /// for the same stream and settings, so a rejected configuration cannot spin.
  private func drainConfigurationUpdates() async {
    defer { configurationUpdateTask = nil }

    var failedUpdate: (context: StreamContext, settings: StreamSettings)?
    while let context = currentStream,
      context.started,
      !context.stopSignaled
    {
      let settings = streamSettings(for: context)
      guard settings != context.appliedSettings else { return }
      if let failedUpdate, failedUpdate.context === context, failedUpdate.settings == settings {
        return
      }

      let configuration = makeConfiguration(with: settings)
      do {
        try await context.stream.updateConfiguration(configuration)
      } catch {
        // The stream keeps running with its previous configuration. A
        // rejected crop reverts to the applied one, because callers compose
        // new regions on `crop`; a newer request is left to the next pass.
        failedUpdate = (context, settings)
        if currentStream === context, crop == settings.crop,
          settings.crop != context.appliedSettings.crop
        {
          crop = context.appliedSettings.crop
        }
        continue
      }
      failedUpdate = nil
      guard currentStream === context else { continue }
      context.appliedSettings = settings
    }
  }

  private func configurePicker() {
    if !Self.pickerConfigured {
      Self.pickerConfigured = true
      var configuration = SCContentSharingPickerConfiguration()
      configuration.allowedPickerModes = .singleWindow
      configuration.excludedBundleIDs = [Bundle.main.bundleIdentifier ?? "dev.local.pip"]
      configuration.allowsChangingSelectedContent = true

      picker.defaultConfiguration = configuration
      // Each PiP owns its own stream, so the system must not cap the count.
      picker.maximumStreamCount = nil
    }
    if let pickerObserver {
      picker.add(pickerObserver)
    }
  }

  private func installWorkspaceObservers() {
    let center = NSWorkspace.shared.notificationCenter
    let sharedFrameGate = frameGate
    let workspaceTransitions = workspaceTransitionBox
    let pauseNotifications: [(Notification.Name, String)] = [
      (NSWorkspace.screensDidSleepNotification, L10n.string("capture.screenUnavailable")),
      (NSWorkspace.sessionDidResignActiveNotification, L10n.string("capture.sessionInactive")),
    ]
    for (name, reason) in pauseNotifications {
      let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        let transitionID = workspaceTransitions.next()
        sharedFrameGate.pauseWorkspace()
        Task { @MainActor [weak self] in
          self?.handleSystemInactive(reason: reason, transitionID: transitionID)
        }
      }
      workspaceObserverTokens.append(token)
    }

    let resumeNotifications: [Notification.Name] = [
      NSWorkspace.screensDidWakeNotification,
      NSWorkspace.sessionDidBecomeActiveNotification,
    ]
    for name in resumeNotifications {
      let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        let transitionID = workspaceTransitions.next()
        sharedFrameGate.resumeWorkspace()
        Task { @MainActor [weak self] in
          self?.handleSystemActive(transitionID: transitionID)
        }
      }
      workspaceObserverTokens.append(token)
    }
  }

  private func handleSystemInactive(reason: String, transitionID: UInt64) {
    guard !userStopped,
      let context = currentStream,
      !context.stopSignaled,
      workspaceTransitionBox.isCurrent(transitionID),
      transitionID > lastWorkspaceTransitionID
    else { return }
    lastWorkspaceTransitionID = transitionID
    frameGate.pauseWorkspace()
    guard !workspaceInactive else { return }

    let alreadySuspended =
      streamInactive || frameSuspended || frameGate.hasFrameSuspension(context.generation)
    workspaceInactive = true
    if !alreadySuspended {
      let suspendedGeneration = advanceGeneration()
      context.generationBox.set(suspendedGeneration)
      frameGate.pause(suspendedGeneration, for: .workspace)
    } else {
      frameGate.pause(context.generation, for: .workspace)
    }
    publish(.suspended(reason))
  }

  private func handleSystemActive(transitionID: UInt64) {
    guard workspaceTransitionBox.isCurrent(transitionID),
      transitionID > lastWorkspaceTransitionID
    else { return }
    lastWorkspaceTransitionID = transitionID
    frameGate.resumeWorkspace()
    workspaceInactive = false

    guard !userStopped, let context = currentStream, !context.stopSignaled else { return }
    frameGate.resume(context.generation, for: .workspace)
    if frameSuspended && !frameGate.hasFrameSuspension(context.generation) {
      frameSuspended = false
      frameSuspensionRevision = nil
    }
    if streamInactive {
      publish(.suspended(L10n.string("capture.paused")))
      return
    }
    if frameSuspended || frameGate.hasFrameSuspension(context.generation) {
      publish(.suspended(L10n.string("capture.paused")))
      return
    }

    publish(.running(context.title))
  }

  private func handlePickerCancel(_ event: PickerStreamEvent) {
    guard isPickerPresentationEvent(event.stream) else { return }
    pickerPresentation = nil
    guard selectionInProgress, stopTask == nil, !userStopped else {
      // The sheet outlived the selection (list pick or stop); only the
      // presentation and its activation end.
      updatePickerActivation()
      return
    }

    selectionInProgress = false
    updatePickerActivation()
    let previousState = stateBeforeSelection
    stateBeforeSelection = nil
    if let previousState,
      Self.canRestoreSelectionState(
        previousState, currentStream: currentStream,
        replacementInFlight: replacementTask != nil)
    {
      publish(previousState)
    } else if let currentStream,
      !currentStream.stopSignaled
    {
      publish(.running(currentStream.title))
    } else if case .selecting = state {
      publish(.idle)
    }
  }

  private func handlePickerStartFailure() {
    // The failure carries no stream, so only the presenting session owns it.
    guard isPickerPresentationEvent(nil) else { return }
    pickerPresentation = nil
    guard selectionInProgress, stopTask == nil, !userStopped else {
      updatePickerActivation()
      return
    }

    selectionInProgress = false
    updatePickerActivation()
    let previousState = stateBeforeSelection
    stateBeforeSelection = nil
    if let previousState,
      Self.canRestoreSelectionState(
        previousState, currentStream: currentStream,
        replacementInFlight: replacementTask != nil)
    {
      publish(previousState)
    } else if let currentStream,
      !currentStream.stopSignaled
    {
      publish(.running(currentStream.title))
    } else if case .selecting = state {
      publish(.idle)
    } else if currentStream == nil {
      publish(.failed(L10n.string("capture.pickerUnavailable")))
    }
  }

  private func handlePickerUpdate(_ update: PickerUpdate) {
    let fromPresentation = isPickerPresentationEvent(update.stream)
    if fromPresentation {
      pickerPresentation = nil
    }
    guard !userStopped, stopTask == nil else {
      updatePickerActivation()
      return
    }
    if !fromPresentation {
      // Otherwise only a change of this session's live stream, e.g. from the
      // system screen-sharing menu, belongs here.
      guard let associatedStream = update.stream,
        let currentStream,
        !currentStream.stopSignaled,
        associatedStream === currentStream.stream
      else { return }
    }

    guard update.filter.style == .window,
      update.filter.includedWindows.count == 1
    else {
      // A late sheet choice must not fail a source picked from the list.
      guard selectionInProgress || !fromPresentation else {
        updatePickerActivation()
        return
      }
      selectionInProgress = false
      updatePickerActivation()
      let previousState = stateBeforeSelection
      stateBeforeSelection = nil
      if let previousState,
        Self.canRestoreSelectionState(
          previousState, currentStream: currentStream,
          replacementInFlight: replacementTask != nil)
      {
        publish(previousState)
      } else {
        publish(.failed(L10n.string("capture.selectionUnavailable")))
      }
      return
    }

    // The latest user choice wins, even over a source picked from the list
    // while the sheet was open.
    acceptSource(filter: update.filter, title: Self.title(for: update.filter))
  }

  /// Whether a picker event answers the sheet this session presented. Events
  /// without a stream go to the presenting session, which is the only one
  /// holding a presentation.
  private func isPickerPresentationEvent(_ stream: SCStream?) -> Bool {
    guard let pickerPresentation else { return false }
    guard let stream else { return true }
    return stream === pickerPresentation.stream
  }

  /// Common entry for a new source, from the picker or the in-app list. Ends
  /// any open selection and queues the source behind in-flight replacements.
  /// A still-open sheet keeps its presentation; its later choice replaces
  /// this source.
  private func acceptSource(filter: SCContentFilter, title: String) {
    selectionInProgress = false
    stateBeforeSelection = nil
    // A crop describes a region of the previous window only.
    crop = nil
    let operation = nextOperationID()
    pendingSource = PendingSource(filter: filter, title: title, operationID: operation)
    updatePickerActivation()
    publish(.starting)
    scheduleReplacement()
  }

  private func scheduleReplacement() {
    guard replacementTask == nil else { return }
    replacementTask = Task { @MainActor [weak self] in
      guard let self else { return }
      await self.drainPendingSources()
    }
  }

  private func drainPendingSources() async {
    defer {
      replacementTask = nil
      updatePickerActivation()
    }

    while !userStopped {
      guard let source = pendingSource else { return }
      pendingSource = nil
      await replace(with: source)
    }
  }

  private func replace(with source: PendingSource) async {
    guard !userStopped, source.operationID == operationID else { return }

    publish(.starting)
    var streamGeneration = advanceGeneration()

    if let oldStream = currentStream {
      await stop(oldStream, intentionally: true)
    }
    currentStream = nil
    streamInactive = false
    frameSuspended = false
    frameSuspensionRevision = nil

    guard isOperationCurrent(source.operationID) else { return }
    if generation != streamGeneration {
      streamGeneration = advanceGeneration()
    }

    let windowID = Self.windowID(for: source.filter)
    let windowSize =
      windowID.flatMap(Self.liveWindowSize(of:)) ?? source.filter.contentRect.size
    let settings = streamSettings(for: source.filter, windowSize: windowSize)
    let configuration = makeConfiguration(with: settings)
    let generationBox = GenerationBox(streamGeneration)
    let output = StreamOutputBridge(
      generationBox: generationBox,
      frameGate: frameGate,
      onFrame: onFrame,
      onStatus: { [weak self] event in
        Task { @MainActor [weak self] in
          self?.handleFrameStatus(event)
        }
      }
    )
    let delegate = StreamDelegateBridge(
      onStop: { [weak self] event in
        Task { @MainActor [weak self] in
          await self?.handleUnexpectedStop(event)
        }
      },
      onActive: { [weak self] event in
        Task { @MainActor [weak self] in
          self?.handleStreamActive(event)
        }
      },
      onInactive: { [weak self] event in
        Task { @MainActor [weak self] in
          self?.handleStreamInactive(event)
        }
      },
      generationBox: generationBox,
      frameGate: frameGate
    )
    let context = StreamContext(
      stream: SCStream(filter: source.filter, configuration: configuration, delegate: delegate),
      output: output,
      delegate: delegate,
      generationBox: generationBox,
      title: source.title,
      filter: source.filter,
      sourceWindowID: windowID,
      windowSize: windowSize,
      appliedSettings: settings
    )
    currentStream = context

    do {
      try context.stream.addStreamOutput(
        output,
        type: .screen,
        sampleHandlerQueue: sampleQueue
      )
      context.outputAdded = true
      guard isOperationCurrent(source.operationID), currentStream === context else {
        await stop(context, intentionally: true)
        return
      }

      // ScreenCaptureKit may deliver the first frame before startCapture()
      // returns, so the gate must be open while the start request is in flight.
      frameGate.resume(streamGeneration)
      context.startRequested = true
      try await context.stream.startCapture()
      context.startRequested = false
      context.started = true
      guard isOperationCurrent(source.operationID), currentStream === context else {
        await stop(context, intentionally: true)
        return
      }

      if workspaceInactive {
        frameGate.pause(context.generation, for: .workspace)
        publish(.suspended(L10n.string("capture.screenUnavailable")))
      } else if streamInactive {
        frameGate.pause(context.generation, for: .stream)
        publish(.suspended(L10n.string("capture.paused")))
      } else if frameSuspended {
        publish(.suspended(L10n.string("capture.paused")))
      } else {
        frameGate.resume(context.generation)
        publish(.running(source.title))
      }
      applyConfigurationIfNeeded()
    } catch {
      await stop(context, intentionally: true)
      if currentStream === context {
        currentStream = nil
      }
      frameSuspended = false
      frameSuspensionRevision = nil
      frameGate.pause(streamGeneration)

      guard isOperationCurrent(source.operationID) else { return }
      _ = advanceGeneration()
      publish(.failed(L10n.string("capture.unavailable")))
    }
  }

  private func streamSettings(for context: StreamContext) -> StreamSettings {
    streamSettings(for: context.filter, windowSize: context.windowSize)
  }

  /// `windowSize` is the source window's current size in points; the filter's
  /// `contentRect` only records the size when the filter was made.
  private func streamSettings(for filter: SCContentFilter, windowSize: CGSize) -> StreamSettings {
    let sourceRect = self.sourceRect(for: filter, windowSize: windowSize)
    return StreamSettings(
      outputSize: outputSize(for: filter, windowSize: windowSize, capturing: sourceRect),
      frameRate: frameRate,
      crop: sourceRect == nil ? nil : crop,
      sourceRect: sourceRect
    )
  }

  /// The crop in window points with a top-left origin, as
  /// `SCStreamConfiguration.sourceRect` expects for single-window filters.
  /// Edges snap to whole source pixels so the captured pixels have exactly
  /// the aspect the output is sized for.
  private func sourceRect(for filter: SCContentFilter, windowSize: CGSize) -> CGRect? {
    guard let crop else { return nil }
    guard windowSize.width.isFinite, windowSize.height.isFinite,
      windowSize.width > 0, windowSize.height > 0
    else { return nil }
    let pointScale = max(CGFloat(filter.pointPixelScale), 1)
    let pixelWidth = windowSize.width * pointScale
    let pixelHeight = windowSize.height * pointScale
    let minX = (crop.minX * pixelWidth).rounded()
    let minY = (crop.minY * pixelHeight).rounded()
    let maxX = max((crop.maxX * pixelWidth).rounded(), minX + 1)
    let maxY = max((crop.maxY * pixelHeight).rounded(), minY + 1)
    return CGRect(
      x: minX / pointScale,
      y: minY / pointScale,
      width: (maxX - minX) / pointScale,
      height: (maxY - minY) / pointScale
    )
  }

  /// Fits the captured region (the crop, else the whole window) inside the
  /// target without exceeding its native pixels, keeping its aspect.
  private func outputSize(
    for filter: SCContentFilter,
    windowSize: CGSize,
    capturing sourceRect: CGRect?
  ) -> CGSize {
    let capturedSize = sourceRect?.size ?? windowSize
    let pointScale = max(CGFloat(filter.pointPixelScale), 1)
    let sourceWidth = max(capturedSize.width * pointScale, 1)
    let sourceHeight = max(capturedSize.height * pointScale, 1)
    let target = targetOutputSize ?? CGSize(width: 1280, height: 720)
    let scale = min(1, target.width / sourceWidth, target.height / sourceHeight)

    let width = max((sourceWidth * scale).rounded(), 1)
    let height = max((sourceHeight * scale).rounded(), 1)
    return CGSize(width: width, height: height)
  }

  private func makeConfiguration(with settings: StreamSettings) -> SCStreamConfiguration {
    let configuration = SCStreamConfiguration()
    configuration.width = Int(settings.outputSize.width)
    configuration.height = Int(settings.outputSize.height)
    configuration.minimumFrameInterval = CMTime(
      value: 1,
      timescale: CMTimeScale(settings.frameRate.framesPerSecond)
    )
    // Left unset (zero) the whole window is captured, which is also how a
    // live update clears a previous crop.
    if let sourceRect = settings.sourceRect {
      configuration.sourceRect = sourceRect
    }
    configuration.pixelFormat = kCVPixelFormatType_32BGRA
    configuration.scalesToFit = true
    configuration.preservesAspectRatio = true
    configuration.showsCursor = false
    configuration.capturesAudio = false
    configuration.queueDepth = 3
    configuration.ignoreShadowsSingleWindow = true
    configuration.includeChildWindows = true
    return configuration
  }

  private func stop(_ context: StreamContext, intentionally: Bool) async {
    let identifier = ObjectIdentifier(context.stream)
    context.stopSignaled = true
    frameGate.pause(context.generation)
    if intentionally {
      intentionalStops.insert(identifier)
    }
    defer {
      intentionalStops.remove(identifier)
      if currentStream === context {
        currentStream = nil
      }
    }

    if context.startRequested || context.started {
      _ = try? await context.stream.stopCapture()
    }
    if context.outputAdded {
      _ = try? context.stream.removeStreamOutput(context.output, type: .screen)
      context.outputAdded = false
    }
    context.startRequested = false
    context.started = false
  }

  private func handleUnexpectedStop(_ event: StreamStopEvent) async {
    guard let context = currentStream,
      context.stream === event.stream,
      !intentionalStops.contains(ObjectIdentifier(event.stream))
    else { return }
    await handleStopped(
      context,
      stoppedByUser: event.stoppedByUser,
      failureMessage: event.message
    )
  }

  private func handleFrameStatus(_ event: StreamFrameStatusEvent) {
    guard let context = currentStream,
      context.stream === event.stream,
      !context.stopSignaled,
      !intentionalStops.contains(ObjectIdentifier(event.stream))
    else { return }

    switch event.status {
    case .suspended, .blank:
      guard !userStopped,
        frameGate.isFrameSuspended(context.generation, revision: event.revision)
      else {
        return
      }
      frameSuspended = true
      frameSuspensionRevision = event.revision == 0 ? nil : event.revision
      publish(
        .suspended(
          L10n.string(workspaceInactive ? "capture.screenUnavailable" : "capture.paused")
        ))
    case .complete:
      guard frameSuspended || streamInactive,
        event.revision == 0 || frameSuspensionRevision == event.revision
      else {
        return
      }
      if frameGate.hasFrameSuspension(context.generation)
        && !frameGate.isFrameSuspended(
          context.generation,
          revision: event.revision
        )
      {
        return
      }
      streamInactive = frameGate.hasStreamSuspension(context.generation)
      frameSuspended = false
      frameSuspensionRevision = nil
      _ = frameGate.resumeFrameSuspension(
        context.generation,
        revision: event.revision
      )
      if workspaceInactive {
        publish(.suspended(L10n.string("capture.screenUnavailable")))
      } else if streamInactive {
        publish(.suspended(L10n.string("capture.paused")))
      } else {
        publish(.running(context.title))
      }
    case .stopped:
      context.stopSignaled = true
      frameGate.pause(context.generation)
      Task { @MainActor [weak self] in
        await self?.handleStoppedFrame(event)
      }
    default:
      break
    }
  }

  private func handleStoppedFrame(_ event: StreamFrameStatusEvent) async {
    guard let context = currentStream,
      context.stream === event.stream,
      !intentionalStops.contains(ObjectIdentifier(event.stream))
    else { return }
    await handleStopped(context)
  }

  private func handleStopped(
    _ context: StreamContext,
    stoppedByUser: Bool = false,
    failureMessage: String? = nil
  ) async {
    guard currentStream === context else { return }
    context.stopSignaled = true
    let stoppedOperation = operationID
    let wasUserStopped = userStopped
    currentStream = nil
    streamInactive = false
    frameSuspended = false
    frameSuspensionRevision = nil
    frameGate.pause(context.generation)
    _ = advanceGeneration()
    await stop(context, intentionally: false)
    updatePickerActivation()

    // ScreenCaptureKit reports a closed window as `userStopped`, so the
    // window's disappearance outranks the stop reason; only a stop requested
    // through this session does not.
    let wasRequestedHere = wasUserStopped || userStopped
    var sourceClosed = false
    if !wasRequestedHere, let windowID = context.sourceWindowID {
      sourceClosed = await Self.sourceWindowDisappears(windowID)
    }

    guard operationID == stoppedOperation, currentStream == nil else { return }
    if wasRequestedHere || userStopped {
      publish(.stopped(L10n.string("capture.stopped")))
    } else if sourceClosed {
      reportSourceClosed(context)
    } else if stoppedByUser {
      publish(.stopped(L10n.string("capture.stopped")))
    } else {
      publish(.failed(failureMessage ?? L10n.string("capture.ended")))
    }
  }

  /// ScreenCaptureKit ends a window stream slightly before the window server
  /// drops the window (about 0.25 s in practice), so a stop is matched against
  /// the window's disappearance for a short grace period.
  private static func sourceWindowDisappears(_ windowID: CGWindowID) async -> Bool {
    let deadline = ContinuousClock.now + sourceCloseGracePeriod
    while WindowCatalog.windowExists(windowID) {
      guard ContinuousClock.now < deadline else { return false }
      do {
        try await Task.sleep(for: .milliseconds(50))
      } catch {
        return false
      }
    }
    return true
  }

  /// Polls the window server while a stream exists: a resized source re-maps
  /// the crop and output size, and a source window that disappears without
  /// ending the stream is reported closed (a backstop). The task belongs to
  /// one stream; any `currentStream` change cancels it.
  private func restartSourceMonitor() {
    sourceMonitorTask?.cancel()
    sourceMonitorTask = nil
    guard let context = currentStream, let windowID = context.sourceWindowID else { return }

    let interval = Self.sourcePollInterval
    sourceMonitorTask = Task { @MainActor [weak self] in
      while true {
        do {
          try await Task.sleep(for: interval)
        } catch {
          return
        }
        guard let self, self.currentStream === context else { return }
        if let windowSize = CaptureSession.liveWindowSize(of: windowID) {
          if windowSize != context.windowSize {
            context.windowSize = windowSize
            self.applyConfigurationIfNeeded()
          }
          continue
        }
        guard self.canReportSourceClosed(context),
          !WindowCatalog.windowExists(windowID)
        else { continue }
        // Closing clears `currentStream`, which cancels this task, so it runs
        // on its own task to keep its stop request uncancelled.
        Task { @MainActor [weak self] in
          await self?.handleSourceClosed(context)
        }
        return
      }
    }
  }

  /// A source-closed stop must not race a user stop, a source replacement,
  /// or an open picker; those end or replace `context` themselves, and the
  /// monitor retries on its next tick.
  private func canReportSourceClosed(_ context: StreamContext) -> Bool {
    currentStream === context
      && !context.stopSignaled
      && !userStopped
      && stopTask == nil
      && replacementTask == nil
      && !selectionInProgress
  }

  private func handleSourceClosed(_ context: StreamContext) async {
    guard canReportSourceClosed(context) else { return }
    context.stopSignaled = true
    let stoppedOperation = operationID
    currentStream = nil
    streamInactive = false
    frameSuspended = false
    frameSuspensionRevision = nil
    frameGate.pause(context.generation)
    _ = advanceGeneration()
    await stop(context, intentionally: true)
    updatePickerActivation()

    guard operationID == stoppedOperation, currentStream == nil, !userStopped,
      !selectionInProgress
    else { return }
    reportSourceClosed(context)
  }

  /// Publishes the closed state and fires `onSourceWindowClosed` once per
  /// stream. While the user is choosing a replacement the callback is held
  /// back so an auto-close cannot dismiss the PiP mid-selection.
  private func reportSourceClosed(_ context: StreamContext) {
    publish(.stopped(L10n.string("capture.sourceClosed")))
    guard !context.sourceClosedReported, !selectionInProgress else { return }
    context.sourceClosedReported = true
    onSourceWindowClosed?()
  }

  private func handleStreamActive(_ event: StreamEvent) {
    guard !userStopped,
      let context = currentStream,
      context.stream === event.stream,
      !context.stopSignaled,
      event.isCurrent,
      event.transitionID > context.lastStreamTransitionID
    else { return }
    context.lastStreamTransitionID = event.transitionID

    streamInactive = false
    frameGate.resume(context.generation, for: .stream)
    if frameSuspended && !frameGate.hasFrameSuspension(context.generation) {
      frameSuspended = false
      frameSuspensionRevision = nil
    }
    guard !workspaceInactive else {
      frameGate.pause(context.generation, for: .workspace)
      publish(.suspended(L10n.string("capture.screenUnavailable")))
      return
    }
    guard !frameSuspended,
      !frameGate.hasFrameSuspension(context.generation)
    else {
      publish(.suspended(L10n.string("capture.paused")))
      return
    }
    publish(.running(context.title))
  }

  private func handleStreamInactive(_ event: StreamEvent) {
    guard !userStopped,
      let context = currentStream,
      context.stream === event.stream,
      !context.stopSignaled,
      event.isCurrent,
      event.transitionID > context.lastStreamTransitionID
    else { return }
    context.lastStreamTransitionID = event.transitionID
    guard !streamInactive, frameGate.hasStreamSuspension(context.generation) else { return }
    streamInactive = true
    publish(
      .suspended(
        L10n.string(workspaceInactive ? "capture.screenUnavailable" : "capture.paused")
      ))
  }

  private func publish(_ newState: CaptureState) {
    guard state != newState else { return }
    state = newState
    onStateChange?(newState)
  }

  /// `SCContentSharingPicker.isActive` keeps the app listed in the system
  /// screen-sharing menu bar item even without a running stream, so it must
  /// only stay on while a selection or capture is in flight. The flag is
  /// process-wide: each session holds at most one activation while it has a
  /// selection, an open picker, a pending source, or a stream, and the picker
  /// turns off only once no session holds one.
  private func updatePickerActivation() {
    let needsPicker =
      selectionInProgress
      || pickerPresentation != nil
      || currentStream != nil
      || pendingSource != nil
      || replacementTask != nil
    guard needsPicker != holdsPickerActivation else { return }
    holdsPickerActivation = needsPicker
    Self.adjustPickerActivations(by: needsPicker ? 1 : -1)
  }

  private static func adjustPickerActivations(by delta: Int) {
    let wasActive = pickerActivationCount > 0
    pickerActivationCount = max(pickerActivationCount + delta, 0)
    let isActive = pickerActivationCount > 0
    guard isActive != wasActive else { return }
    SCContentSharingPicker.shared.isActive = isActive
  }

  private func advanceGeneration() -> UInt64 {
    if generation < UInt64.max {
      generation += 1
    }
    frameGate.advance(to: generation)
    onReset(generation)
    return generation
  }

  private func nextOperationID() -> UInt64 {
    if operationID < UInt64.max {
      operationID += 1
    }
    return operationID
  }

  private func isOperationCurrent(_ operation: UInt64) -> Bool {
    !userStopped && operation == operationID
  }

  /// A `.starting` snapshot taken while a replacement was in flight is stale
  /// once that replacement has published its terminal state; `replacementTask`
  /// is cleared in `drainPendingSources`' defer with no await after that publish.
  private static func canRestoreSelectionState(
    _ previousState: CaptureState,
    currentStream: StreamContext?,
    replacementInFlight: Bool
  ) -> Bool {
    guard currentStream?.stopSignaled != true else { return false }
    switch previousState {
    case .running, .suspended:
      return currentStream != nil
    case .starting:
      return replacementInFlight
    case .idle, .selecting, .stopped, .failed:
      return true
    }
  }

  private static func title(for filter: SCContentFilter) -> String {
    guard
      let title = filter.includedWindows.first?.title?.trimmingCharacters(
        in: .whitespacesAndNewlines),
      !title.isEmpty
    else {
      return L10n.string("capture.untitledWindow")
    }
    return title
  }

  private static func windowID(for filter: SCContentFilter) -> CGWindowID? {
    filter.includedWindows.first?.windowID
  }

  /// The window's current size in points (`kCGWindowBounds`), or `nil` when
  /// the window server no longer lists it with usable bounds.
  private static func liveWindowSize(of windowID: CGWindowID) -> CGSize? {
    guard
      let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID)
        as? [[String: Any]],
      let entry = info.first(where: { entry in
        (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID
      }),
      let boundsDictionary = entry[kCGWindowBounds as String] as? NSDictionary,
      let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary)
    else { return nil }
    let size = bounds.size
    guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0
    else { return nil }
    return size
  }

  private static func sanitizedCrop(_ rect: CGRect) -> CGRect? {
    guard rect.origin.x.isFinite, rect.origin.y.isFinite,
      rect.width.isFinite, rect.height.isFinite
    else { return nil }
    let standardized = rect.standardized
    let minX = min(max(standardized.minX, 0), 1)
    let minY = min(max(standardized.minY, 0), 1)
    let maxX = min(max(standardized.maxX, 0), 1)
    let maxY = min(max(standardized.maxY, 0), 1)
    let width = maxX - minX
    let height = maxY - minY
    guard width >= minimumCropFraction, height >= minimumCropFraction,
      width < 1 || height < 1
    else { return nil }
    return CGRect(x: minX, y: minY, width: width, height: height)
  }

  deinit {
    if let pickerObserver {
      picker.remove(pickerObserver)
    }
    sourceMonitorTask?.cancel()
    if holdsPickerActivation {
      // The activation count is main-actor state; deinit is nonisolated.
      Task { @MainActor in
        CaptureSession.adjustPickerActivations(by: -1)
      }
    }
    let center = NSWorkspace.shared.notificationCenter
    for token in workspaceObserverTokens {
      center.removeObserver(token)
    }
  }
}

private struct PendingSource {
  let filter: SCContentFilter
  let title: String
  let operationID: UInt64
}

/// A `start(filter:title:)` request that arrived while a stop was in flight.
private struct PendingStart {
  let filter: SCContentFilter
  let title: String
}

/// The stream properties that can change while capturing. A stream records
/// the last settings it accepted so live updates are issued only on change.
private struct StreamSettings: Equatable {
  let outputSize: CGSize
  let frameRate: FrameRate
  /// Normalized region `sourceRect` was derived from; `nil` when uncropped.
  let crop: CGRect?
  /// Window points, top-left origin; `nil` captures the whole window.
  let sourceRect: CGRect?
}

/// A picker sheet a session presented, until the picker reports back.
private struct PickerPresentation {
  /// Stream the sheet was presented for; `nil` for a fresh selection.
  let stream: SCStream?
}

private final class GenerationBox: @unchecked Sendable {
  private let lock = NSLock()
  private var valueStorage: UInt64

  init(_ value: UInt64) {
    valueStorage = value
  }

  var value: UInt64 {
    lock.lock()
    defer { lock.unlock() }
    return valueStorage
  }

  func set(_ value: UInt64) {
    lock.lock()
    valueStorage = value
    lock.unlock()
  }
}

private final class TransitionBox: @unchecked Sendable {
  private let lock = NSLock()
  private var valueStorage: UInt64 = 0

  func next() -> UInt64 {
    lock.lock()
    if valueStorage < UInt64.max {
      valueStorage += 1
    }
    let value = valueStorage
    lock.unlock()
    return value
  }

  func isCurrent(_ value: UInt64) -> Bool {
    lock.lock()
    let isCurrent = valueStorage == value
    lock.unlock()
    return isCurrent
  }
}

private final class StreamContext: @unchecked Sendable {
  let stream: SCStream
  let output: StreamOutputBridge
  let delegate: StreamDelegateBridge
  let generationBox: GenerationBox
  let title: String
  let filter: SCContentFilter
  /// Window captured by this stream, used to detect that it closed.
  let sourceWindowID: CGWindowID?
  /// Source window size in points, refreshed by the source monitor and on
  /// crop changes; the crop and output size are mapped onto it.
  var windowSize: CGSize
  /// Settings the stream currently runs with (initial or last live update).
  var appliedSettings: StreamSettings
  /// `onSourceWindowClosed` fires at most once per stream.
  var sourceClosedReported = false
  var outputAdded = false
  var startRequested = false
  var started = false
  var stopSignaled = false
  var lastStreamTransitionID: UInt64 = 0

  var generation: UInt64 {
    generationBox.value
  }

  init(
    stream: SCStream,
    output: StreamOutputBridge,
    delegate: StreamDelegateBridge,
    generationBox: GenerationBox,
    title: String,
    filter: SCContentFilter,
    sourceWindowID: CGWindowID?,
    windowSize: CGSize,
    appliedSettings: StreamSettings
  ) {
    self.stream = stream
    self.output = output
    self.delegate = delegate
    self.generationBox = generationBox
    self.title = title
    self.filter = filter
    self.sourceWindowID = sourceWindowID
    self.windowSize = windowSize
    self.appliedSettings = appliedSettings
  }
}

private enum FrameGatePauseReason: UInt8 {
  case manual = 1
  case workspace = 2
  case stream = 4
  case frame = 8
}

private final class FrameGate: @unchecked Sendable {
  private let lock = NSLock()
  private var generation: UInt64 = 0
  private var pauseReasons: UInt8 = 0
  private var frameSuspensionRevision: UInt64?
  private var workspacePaused = false
  private var acceptsFrames = false

  func advance(to generation: UInt64) {
    lock.lock()
    self.generation = generation
    pauseReasons = 0
    frameSuspensionRevision = nil
    updateAcceptance()
    lock.unlock()
  }

  func pauseWorkspace() {
    lock.lock()
    workspacePaused = true
    acceptsFrames = false
    lock.unlock()
  }

  func resumeWorkspace() {
    lock.lock()
    workspacePaused = false
    updateAcceptance()
    lock.unlock()
  }

  func pause(_ generation: UInt64) {
    pause(generation, for: .manual)
  }

  func resume(_ generation: UInt64) {
    lock.lock()
    let stale = self.generation != generation
    if !stale {
      pauseReasons = 0
      frameSuspensionRevision = nil
      updateAcceptance()
    }
    lock.unlock()
  }

  func pause(_ generation: UInt64, for reason: FrameGatePauseReason) {
    lock.lock()
    guard self.generation == generation else {
      lock.unlock()
      return
    }
    pauseReasons |= reason.rawValue
    if reason == .frame {
      frameSuspensionRevision = nil
    }
    acceptsFrames = false
    lock.unlock()
  }

  @discardableResult
  func resume(_ generation: UInt64, for reason: FrameGatePauseReason) -> Bool {
    lock.lock()
    guard self.generation == generation else {
      lock.unlock()
      return false
    }
    let wasPaused = (pauseReasons & reason.rawValue) != 0
    pauseReasons &= ~reason.rawValue
    if reason == .frame {
      frameSuspensionRevision = nil
    }
    updateAcceptance()
    lock.unlock()
    return wasPaused
  }

  func hasStreamSuspension(_ generation: UInt64) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return self.generation == generation
      && (pauseReasons & FrameGatePauseReason.stream.rawValue) != 0
  }

  func pauseFrameSuspension(_ generation: UInt64, revision: UInt64) -> Bool {
    lock.lock()
    guard self.generation == generation else {
      lock.unlock()
      return false
    }
    guard (pauseReasons & FrameGatePauseReason.frame.rawValue) == 0 else {
      let matches = frameSuspensionRevision == revision
      lock.unlock()
      return matches
    }

    pauseReasons |= FrameGatePauseReason.frame.rawValue
    frameSuspensionRevision = revision
    acceptsFrames = false
    lock.unlock()
    return true
  }

  // nil means no matching suspension; false means a stale generation.
  // true means recovery occurred, even if another pause still blocks delivery.
  func resumeFrameSuspensionAndDeliver(
    _ frame: CaptureFrame,
    revision: UInt64,
    to onFrame: @Sendable (CaptureFrame) -> Void
  ) -> Bool? {
    lock.lock()
    guard generation == frame.generation else {
      lock.unlock()
      return false
    }
    guard (pauseReasons & FrameGatePauseReason.frame.rawValue) != 0,
      revision == 0 || frameSuspensionRevision == revision
    else {
      lock.unlock()
      return nil
    }

    pauseReasons &= ~FrameGatePauseReason.frame.rawValue
    frameSuspensionRevision = nil
    updateAcceptance()
    guard acceptsFrames else {
      lock.unlock()
      return true
    }
    onFrame(frame)
    lock.unlock()
    return true
  }

  func resumeFrameSuspension(_ generation: UInt64, revision: UInt64) -> Bool {
    lock.lock()
    guard self.generation == generation else {
      lock.unlock()
      return false
    }
    guard (pauseReasons & FrameGatePauseReason.frame.rawValue) != 0,
      revision == 0 || frameSuspensionRevision == revision
    else {
      lock.unlock()
      return false
    }

    pauseReasons &= ~FrameGatePauseReason.frame.rawValue
    frameSuspensionRevision = nil
    updateAcceptance()
    lock.unlock()
    return true
  }

  func hasFrameSuspension(_ generation: UInt64) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return self.generation == generation
      && (pauseReasons & FrameGatePauseReason.frame.rawValue) != 0
  }

  func isFrameSuspended(_ generation: UInt64, revision: UInt64) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard self.generation == generation,
      (pauseReasons & FrameGatePauseReason.frame.rawValue) != 0
    else {
      return false
    }
    return revision == 0 || frameSuspensionRevision == revision
  }

  func deliver(
    _ frame: CaptureFrame,
    to onFrame: @Sendable (CaptureFrame) -> Void
  ) {
    lock.lock()
    guard generation == frame.generation else {
      lock.unlock()
      return
    }
    guard acceptsFrames else {
      lock.unlock()
      return
    }
    onFrame(frame)
    lock.unlock()
  }

  private func updateAcceptance() {
    acceptsFrames = !workspacePaused && pauseReasons == 0
  }
}

private final class StreamOutputBridge: NSObject, SCStreamOutput, @unchecked Sendable {
  private let generationBox: GenerationBox
  private let frameGate: FrameGate
  private let onFrame: @Sendable (CaptureFrame) -> Void
  private let onStatus: @Sendable (StreamFrameStatusEvent) -> Void
  private let statusLock = NSLock()
  private var nextFrameRevision: UInt64 = 0
  private var pendingFrameRevision: UInt64?
  private var stoppedStatusSent = false

  init(
    generationBox: GenerationBox,
    frameGate: FrameGate,
    onFrame: @escaping @Sendable (CaptureFrame) -> Void,
    onStatus: @escaping @Sendable (StreamFrameStatusEvent) -> Void
  ) {
    self.generationBox = generationBox
    self.frameGate = frameGate
    self.onFrame = onFrame
    self.onStatus = onStatus
  }

  func stream(
    _ stream: SCStream,
    didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    guard type == .screen else {
      return
    }
    guard sampleBuffer.isValid else {
      return
    }
    guard let metadata = Self.metadata(from: sampleBuffer) else {
      return
    }
    guard let status = Self.status(from: metadata) else {
      return
    }

    switch status {
    case .complete, .started:
      break
    case .idle:
      // An idle frame means the source did not change. Keep the last
      // delivered image and do not turn it into a capture error.
      return
    case .blank, .suspended:
      let generation = generationBox.value
      guard let revision = beginFrameSuspension(generation: generation) else {
        return
      }
      onStatus(
        StreamFrameStatusEvent(
          stream: stream,
          status: status,
          revision: revision
        ))
      return
    case .stopped:
      frameGate.pause(generationBox.value)
      guard shouldReportStopped() else {
        return
      }
      onStatus(StreamFrameStatusEvent(stream: stream, status: status))
      return
    @unknown default:
      return
    }

    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
      CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA
    else {
      return
    }

    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    guard width > 0, height > 0,
      let contentRect = Self.contentRect(
        from: metadata,
        width: width,
        height: height
      )
    else {
      return
    }

    let generation = generationBox.value
    let frame = CaptureFrame(
      pixelBuffer: pixelBuffer,
      contentRect: contentRect,
      displayTime: Self.uint64Value(metadata[.displayTime]),
      generation: generation
    )

    // A valid complete frame is authoritative recovery, even when the
    // system does not send a matching streamDidBecomeActive callback.
    let recoveredStream = status == .complete && frameGate.resume(generation, for: .stream)
    if status == .complete,
      let recovery = recoverFrameSuspension(frame)
    {
      if recovery.shouldNotify {
        onStatus(
          StreamFrameStatusEvent(
            stream: stream,
            status: .complete,
            revision: recovery.revision
          ))
      }
    } else {
      frameGate.deliver(frame, to: onFrame)
      if recoveredStream {
        onStatus(StreamFrameStatusEvent(stream: stream, status: .complete))
      }
    }
  }

  private func beginFrameSuspension(generation: UInt64) -> UInt64? {
    statusLock.lock()
    if pendingFrameRevision != nil {
      statusLock.unlock()
      return nil
    }
    if nextFrameRevision == UInt64.max {
      nextFrameRevision = 1
    } else {
      nextFrameRevision += 1
    }
    let revision = nextFrameRevision
    pendingFrameRevision = revision
    statusLock.unlock()

    guard frameGate.pauseFrameSuspension(generation, revision: revision) else {
      statusLock.lock()
      if pendingFrameRevision == revision {
        pendingFrameRevision = nil
      }
      statusLock.unlock()
      return nil
    }
    return revision
  }

  private func recoverFrameSuspension(
    _ frame: CaptureFrame
  ) -> (revision: UInt64, shouldNotify: Bool)? {
    statusLock.lock()
    let revision = pendingFrameRevision
    statusLock.unlock()
    guard let revision else { return nil }

    guard
      let shouldNotify = frameGate.resumeFrameSuspensionAndDeliver(
        frame,
        revision: revision,
        to: onFrame
      )
    else {
      return nil
    }

    statusLock.lock()
    defer { statusLock.unlock() }
    guard pendingFrameRevision == revision else { return nil }
    pendingFrameRevision = nil
    return (revision, shouldNotify)
  }

  private func shouldReportStopped() -> Bool {
    statusLock.lock()
    defer { statusLock.unlock() }
    guard !stoppedStatusSent else { return false }
    stoppedStatusSent = true
    return true
  }

  private static func metadata(from sampleBuffer: CMSampleBuffer) -> [SCStreamFrameInfo: Any]? {
    guard
      let attachments = CMSampleBufferGetSampleAttachmentsArray(
        sampleBuffer,
        createIfNecessary: false
      ) as? [[SCStreamFrameInfo: Any]]
    else {
      return nil
    }
    return attachments.first
  }

  private static func status(from metadata: [SCStreamFrameInfo: Any]) -> SCFrameStatus? {
    let value = metadata[.status]
    if let status = value as? SCFrameStatus {
      return status
    }
    if let status = value as? Int {
      return SCFrameStatus(rawValue: status)
    }
    if let status = value as? NSNumber {
      return SCFrameStatus(rawValue: status.intValue)
    }
    return nil
  }

  private static func contentRect(
    from metadata: [SCStreamFrameInfo: Any],
    width: Int,
    height: Int
  ) -> CGRect? {
    guard let sourceRect = rectValue(metadata[.contentRect]),
      let contentScale = numberValue(metadata[.contentScale]),
      let scaleFactor = numberValue(metadata[.scaleFactor]),
      sourceRect.width > 0,
      sourceRect.height > 0,
      contentScale.isFinite,
      contentScale > 0,
      scaleFactor.isFinite,
      scaleFactor > 0,
      Self.isFinite(sourceRect)
    else {
      return nil
    }

    // SCStreamFrameInfo.contentRect is expressed in source points. The
    // scaleFactor converts those coordinates to output pixels. WWDC's
    // ScreenCaptureKit guidance uses contentScale for restoring native
    // content size, not for locating the content in the output surface.
    let pixelRect = CGRect(
      x: sourceRect.origin.x * scaleFactor,
      y: sourceRect.origin.y * scaleFactor,
      width: sourceRect.width * scaleFactor,
      height: sourceRect.height * scaleFactor
    )
    guard Self.isFinite(pixelRect), pixelRect.width > 0, pixelRect.height > 0 else {
      return nil
    }

    let outputWidth = CGFloat(width)
    let outputHeight = CGFloat(height)
    let minXValue = max(0, min(outputWidth, pixelRect.minX))
    let minYValue = max(0, min(outputHeight, pixelRect.minY))
    let maxXValue = max(0, min(outputWidth, pixelRect.maxX))
    let maxYValue = max(0, min(outputHeight, pixelRect.maxY))
    guard minXValue.isFinite, minYValue.isFinite,
      maxXValue.isFinite, maxYValue.isFinite,
      maxXValue > minXValue, maxYValue > minYValue
    else {
      return nil
    }

    // Values are clamped to the pixel-buffer dimensions before conversion,
    // so malformed but finite metadata can never trap an Int conversion.
    let minX = Int(minXValue.rounded(.down))
    let minY = Int(minYValue.rounded(.down))
    let maxX = Int(maxXValue.rounded(.up))
    let maxY = Int(maxYValue.rounded(.up))
    guard maxX > minX, maxY > minY else { return nil }
    return CGRect(
      x: CGFloat(minX),
      y: CGFloat(minY),
      width: CGFloat(maxX - minX),
      height: CGFloat(maxY - minY)
    )
  }

  private static func isFinite(_ rect: CGRect) -> Bool {
    rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite
      && rect.minX.isFinite && rect.minY.isFinite && rect.maxX.isFinite && rect.maxY.isFinite
  }

  private static func rectValue(_ value: Any?) -> CGRect? {
    if let rect = value as? CGRect {
      return rect
    }
    if let value = value as? NSValue {
      return value.rectValue
    }
    if let dictionary = value as? NSDictionary {
      return CGRect(dictionaryRepresentation: dictionary as CFDictionary)
    }
    return nil
  }

  private static func numberValue(_ value: Any?) -> CGFloat? {
    if let number = value as? NSNumber {
      return CGFloat(number.doubleValue)
    }
    if let value = value as? CGFloat {
      return value
    }
    if let value = value as? Double {
      return CGFloat(value)
    }
    if let value = value as? Float {
      return CGFloat(value)
    }
    return nil
  }

  private static func uint64Value(_ value: Any?) -> UInt64? {
    if let value = value as? UInt64 {
      return value
    }
    if let value = value as? UInt {
      return UInt64(value)
    }
    if let value = value as? Int, value >= 0 {
      return UInt64(value)
    }
    guard let number = value as? NSNumber else { return nil }
    let value = number.doubleValue
    guard value.isFinite, value >= 0 else { return nil }
    return number.uint64Value
  }
}

private final class StreamDelegateBridge: NSObject, SCStreamDelegate, @unchecked Sendable {
  private let onStop: @Sendable (StreamStopEvent) -> Void
  private let onActive: @Sendable (StreamEvent) -> Void
  private let onInactive: @Sendable (StreamEvent) -> Void
  private let generationBox: GenerationBox?
  private let frameGate: FrameGate?
  private let transitionBox = TransitionBox()

  init(
    onStop: @escaping @Sendable (StreamStopEvent) -> Void,
    onActive: @escaping @Sendable (StreamEvent) -> Void,
    onInactive: @escaping @Sendable (StreamEvent) -> Void,
    generationBox: GenerationBox? = nil,
    frameGate: FrameGate? = nil
  ) {
    self.onStop = onStop
    self.onActive = onActive
    self.onInactive = onInactive
    self.generationBox = generationBox
    self.frameGate = frameGate
  }

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    let nsError = error as NSError
    let event = StreamStopEvent(stream: stream, error: nsError)
    if let generationBox, let frameGate {
      frameGate.pause(generationBox.value)
    }
    onStop(event)
  }

  func streamDidBecomeActive(_ stream: SCStream) {
    let transitionID = transitionBox.next()
    if let generationBox, let frameGate {
      frameGate.resume(generationBox.value, for: .stream)
    }
    onActive(
      StreamEvent(
        stream: stream,
        transitionID: transitionID,
        transitionBox: transitionBox
      ))
  }

  func streamDidBecomeInactive(_ stream: SCStream) {
    let transitionID = transitionBox.next()
    if let generationBox, let frameGate {
      frameGate.pause(generationBox.value, for: .stream)
    }
    onInactive(
      StreamEvent(
        stream: stream,
        transitionID: transitionID,
        transitionBox: transitionBox
      ))
  }
}

private final class PickerObserverBridge: NSObject, SCContentSharingPickerObserver,
  @unchecked Sendable
{
  private let onCancel: @Sendable (PickerStreamEvent) -> Void
  private let onUpdate: @Sendable (PickerUpdate) -> Void
  private let onStartFailure: @Sendable (String) -> Void

  init(
    onCancel: @escaping @Sendable (PickerStreamEvent) -> Void,
    onUpdate: @escaping @Sendable (PickerUpdate) -> Void,
    onStartFailure: @escaping @Sendable (String) -> Void
  ) {
    self.onCancel = onCancel
    self.onUpdate = onUpdate
    self.onStartFailure = onStartFailure
  }

  func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
    onCancel(PickerStreamEvent(stream: stream))
  }

  func contentSharingPicker(
    _ picker: SCContentSharingPicker,
    didUpdateWith filter: SCContentFilter,
    for stream: SCStream?
  ) {
    onUpdate(PickerUpdate(filter: filter, stream: stream))
  }

  func contentSharingPickerStartDidFailWithError(_ error: Error) {
    onStartFailure(String(describing: error))
  }
}
private final class StreamEvent: @unchecked Sendable {
  let stream: SCStream
  let transitionID: UInt64
  private let transitionBox: TransitionBox

  var isCurrent: Bool {
    transitionBox.isCurrent(transitionID)
  }

  init(stream: SCStream, transitionID: UInt64, transitionBox: TransitionBox) {
    self.stream = stream
    self.transitionID = transitionID
    self.transitionBox = transitionBox
  }
}

private final class StreamStopEvent: @unchecked Sendable {
  let stream: SCStream
  let message: String
  /// The user ended sharing from the system menu bar control.
  let stoppedByUser: Bool

  init(stream: SCStream, error: NSError) {
    self.stream = stream
    message = "\(error.domain) (\(error.code)): \(error.localizedDescription)"
    stoppedByUser =
      error.domain == SCStreamErrorDomain
      && error.code == SCStreamError.Code.userStopped.rawValue
  }
}

private final class StreamFrameStatusEvent: @unchecked Sendable {
  let stream: SCStream
  let status: SCFrameStatus
  let revision: UInt64

  init(stream: SCStream, status: SCFrameStatus, revision: UInt64 = 0) {
    self.stream = stream
    self.status = status
    self.revision = revision
  }
}

private final class PickerStreamEvent: @unchecked Sendable {
  let stream: SCStream?

  init(stream: SCStream?) {
    self.stream = stream
  }
}

private final class PickerUpdate: @unchecked Sendable {
  let filter: SCContentFilter
  let stream: SCStream?

  init(filter: SCContentFilter, stream: SCStream?) {
    self.filter = filter
    self.stream = stream
  }
}
