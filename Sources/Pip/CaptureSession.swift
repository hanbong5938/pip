import AppKit
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

@MainActor
final class CaptureSession {
  var onStateChange: ((CaptureState) -> Void)?

  private let onFrame: @Sendable (CaptureFrame) -> Void
  private let onReset: @Sendable (UInt64) -> Void
  private nonisolated(unsafe) let picker: SCContentSharingPicker
  private let sampleQueue: DispatchQueue
  private let frameGate = FrameGate()
  private var state: CaptureState = .idle
  private var generation: UInt64 = 0
  private var operationID: UInt64 = 0
  private var currentStream: StreamContext?
  private var pendingSource: PendingSource?
  private var replacementTask: Task<Void, Never>?
  private var stopTask: Task<Void, Never>?
  private var intentionalStops = Set<ObjectIdentifier>()
  private nonisolated(unsafe) var workspaceObserverTokens: [NSObjectProtocol] = []
  private var selectionInProgress = false
  private var stateBeforeSelection: CaptureState?
  private var pickerObserver: PickerObserverBridge?
  private var workspaceInactive = false
  private var streamInactive = false
  private var frameSuspended = false
  private var frameSuspensionRevision: UInt64?
  private let workspaceTransitionBox = TransitionBox()
  private var lastWorkspaceTransitionID: UInt64 = 0
  private var userStopped = false
  private var selectionRequestedAfterStop = false
  private var targetOutputSize: CGSize?
  private var outputSizeUpdateTask: Task<Void, Never>?

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
      selectionRequestedAfterStop = true
      return
    }
    guard !selectionInProgress else { return }

    userStopped = false
    selectionInProgress = true
    stateBeforeSelection = state
    publish(.selecting)
    picker.isActive = true

    if let stream = currentStream?.stream {
      picker.present(for: stream, using: .window)
    } else {
      picker.present(using: .window)
    }
  }

  func stop() async {
    if let stopTask {
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
    publish(.stopped("중지됨"))
    stopTask = nil
    deactivatePickerIfIdle()

    if selectionRequestedAfterStop {
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
    applyOutputSizeIfNeeded()
  }

  private func applyOutputSizeIfNeeded() {
    guard outputSizeUpdateTask == nil,
      let context = currentStream,
      context.started,
      !context.stopSignaled,
      outputSize(for: context.filter) != context.appliedOutputSize
    else { return }

    outputSizeUpdateTask = Task { @MainActor [weak self] in
      guard let self else { return }
      await self.drainOutputSizeUpdates()
    }
  }

  /// Applies the latest target to the current stream, one update at a time.
  /// Targets that arrive while an update is in flight are picked up by the
  /// next loop iteration; a stopping or not-yet-started stream ends the loop.
  private func drainOutputSizeUpdates() async {
    defer { outputSizeUpdateTask = nil }

    var failedUpdate: (context: StreamContext, size: CGSize)?
    while let context = currentStream,
      context.started,
      !context.stopSignaled
    {
      let configuration = makeConfiguration(for: context.filter)
      let size = CGSize(width: configuration.width, height: configuration.height)
      guard size != context.appliedOutputSize else { return }
      if let failedUpdate, failedUpdate.context === context, failedUpdate.size == size {
        return
      }

      do {
        try await context.stream.updateConfiguration(configuration)
      } catch {
        // The stream keeps running with its previous configuration.
        failedUpdate = (context, size)
        continue
      }
      failedUpdate = nil
      guard currentStream === context else { continue }
      context.appliedOutputSize = size
    }
  }

  private func configurePicker() {
    var configuration = SCContentSharingPickerConfiguration()
    configuration.allowedPickerModes = .singleWindow
    configuration.excludedBundleIDs = [Bundle.main.bundleIdentifier ?? "dev.local.pip"]
    configuration.allowsChangingSelectedContent = true

    picker.defaultConfiguration = configuration
    picker.maximumStreamCount = 1
    if let pickerObserver {
      picker.add(pickerObserver)
    }
  }

  private func installWorkspaceObservers() {
    let center = NSWorkspace.shared.notificationCenter
    let sharedFrameGate = frameGate
    let workspaceTransitions = workspaceTransitionBox
    let pauseNotifications: [(Notification.Name, String)] = [
      (NSWorkspace.screensDidSleepNotification, "화면을 사용할 수 없습니다"),
      (NSWorkspace.sessionDidResignActiveNotification, "세션이 비활성 상태입니다"),
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
    guard !userStopped,
      let context = currentStream,
      !context.stopSignaled,
      workspaceTransitionBox.isCurrent(transitionID),
      transitionID > lastWorkspaceTransitionID
    else { return }
    lastWorkspaceTransitionID = transitionID
    frameGate.resumeWorkspace()
    workspaceInactive = false
    frameGate.resume(context.generation, for: .workspace)
    if frameSuspended && !frameGate.hasFrameSuspension(context.generation) {
      frameSuspended = false
      frameSuspensionRevision = nil
    }
    if streamInactive {
      publish(.suspended("캡처가 일시 중지되었습니다"))
      return
    }
    if frameSuspended || frameGate.hasFrameSuspension(context.generation) {
      publish(.suspended("캡처가 일시 중지되었습니다"))
      return
    }

    publish(.running(context.title))
  }

  private func handlePickerCancel(_ event: PickerStreamEvent) {
    guard selectionInProgress, stopTask == nil, !userStopped else { return }
    if let associatedStream = event.stream {
      guard let currentStream,
        !currentStream.stopSignaled,
        associatedStream === currentStream.stream
      else { return }
    }

    selectionInProgress = false
    deactivatePickerIfIdle()
    let previousState = stateBeforeSelection
    stateBeforeSelection = nil
    if let previousState,
      Self.canRestoreSelectionState(previousState, currentStream: currentStream)
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
    guard selectionInProgress, stopTask == nil, !userStopped else { return }

    selectionInProgress = false
    deactivatePickerIfIdle()
    let previousState = stateBeforeSelection
    stateBeforeSelection = nil
    if let previousState,
      Self.canRestoreSelectionState(previousState, currentStream: currentStream)
    {
      publish(previousState)
    } else if let currentStream,
      !currentStream.stopSignaled
    {
      publish(.running(currentStream.title))
    } else if case .selecting = state {
      publish(.idle)
    } else if currentStream == nil {
      publish(.failed("창 선택기를 사용할 수 없습니다"))
    }
  }

  private func handlePickerUpdate(_ update: PickerUpdate) {
    guard !userStopped, stopTask == nil else { return }
    if let associatedStream = update.stream {
      guard let currentStream,
        !currentStream.stopSignaled,
        associatedStream === currentStream.stream
      else { return }
    } else {
      guard selectionInProgress else { return }
    }

    guard update.filter.style == .window,
      update.filter.includedWindows.count == 1
    else {
      selectionInProgress = false
      deactivatePickerIfIdle()
      let previousState = stateBeforeSelection
      stateBeforeSelection = nil
      if let previousState,
        Self.canRestoreSelectionState(previousState, currentStream: currentStream)
      {
        publish(previousState)
      } else {
        publish(.failed("창 선택을 사용할 수 없습니다"))
      }
      return
    }

    selectionInProgress = false
    stateBeforeSelection = nil
    let title = Self.title(for: update.filter)
    let operation = nextOperationID()
    pendingSource = PendingSource(filter: update.filter, title: title, operationID: operation)
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
      deactivatePickerIfIdle()
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

    let configuration = makeConfiguration(for: source.filter)
    let appliedOutputSize = CGSize(width: configuration.width, height: configuration.height)
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
      appliedOutputSize: appliedOutputSize
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
        publish(.suspended("화면을 사용할 수 없습니다"))
      } else if streamInactive {
        frameGate.pause(context.generation, for: .stream)
        publish(.suspended("캡처가 일시 중지되었습니다"))
      } else if frameSuspended {
        publish(.suspended("캡처가 일시 중지되었습니다"))
      } else {
        frameGate.resume(context.generation)
        publish(.running(source.title))
      }
      applyOutputSizeIfNeeded()
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
      publish(.failed("캡처를 사용할 수 없습니다"))
    }
  }

  private func outputSize(for filter: SCContentFilter) -> CGSize {
    let sourceRect = filter.contentRect
    let pointScale = max(CGFloat(filter.pointPixelScale), 1)
    let sourceWidth = max(sourceRect.width * pointScale, 1)
    let sourceHeight = max(sourceRect.height * pointScale, 1)
    let target = targetOutputSize ?? CGSize(width: 1280, height: 720)
    let scale = min(1, target.width / sourceWidth, target.height / sourceHeight)

    let width = max((sourceWidth * scale).rounded(), 1)
    let height = max((sourceHeight * scale).rounded(), 1)
    return CGSize(width: width, height: height)
  }

  private func makeConfiguration(for filter: SCContentFilter) -> SCStreamConfiguration {
    let size = outputSize(for: filter)
    let width = Int(size.width)
    let height = Int(size.height)
    let configuration = SCStreamConfiguration()
    configuration.width = width
    configuration.height = height
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
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
          workspaceInactive ? "화면을 사용할 수 없습니다" : "캡처가 일시 중지되었습니다"
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
        publish(.suspended("화면을 사용할 수 없습니다"))
      } else if streamInactive {
        publish(.suspended("캡처가 일시 중지되었습니다"))
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
    deactivatePickerIfIdle()

    guard operationID == stoppedOperation, currentStream == nil else { return }
    if stoppedByUser || wasUserStopped || userStopped {
      publish(.stopped("중지됨"))
    } else {
      publish(.failed(failureMessage ?? "캡처가 중지되었습니다"))
    }
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
      publish(.suspended("화면을 사용할 수 없습니다"))
      return
    }
    guard !frameSuspended,
      !frameGate.hasFrameSuspension(context.generation)
    else {
      publish(.suspended("캡처가 일시 중지되었습니다"))
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
        workspaceInactive ? "화면을 사용할 수 없습니다" : "캡처가 일시 중지되었습니다"
      ))
  }

  private func publish(_ newState: CaptureState) {
    guard state != newState else { return }
    state = newState
    onStateChange?(newState)
  }

  /// `SCContentSharingPicker.isActive` keeps the app listed in the system
  /// screen-sharing menu bar item even without a running stream, so it must
  /// only stay on while a selection or capture is in flight.
  private func deactivatePickerIfIdle() {
    guard !selectionInProgress,
      currentStream == nil,
      pendingSource == nil,
      replacementTask == nil
    else { return }
    picker.isActive = false
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

  private static func canRestoreSelectionState(
    _ previousState: CaptureState,
    currentStream: StreamContext?
  ) -> Bool {
    guard currentStream?.stopSignaled != true else { return false }
    switch previousState {
    case .running, .suspended, .starting:
      return currentStream != nil
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
      return "창"
    }
    return title
  }

  deinit {
    if let pickerObserver {
      picker.remove(pickerObserver)
    }
    picker.isActive = false
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
  var appliedOutputSize: CGSize
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
    appliedOutputSize: CGSize
  ) {
    self.stream = stream
    self.output = output
    self.delegate = delegate
    self.generationBox = generationBox
    self.title = title
    self.filter = filter
    self.appliedOutputSize = appliedOutputSize
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
