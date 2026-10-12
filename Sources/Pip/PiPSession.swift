import AppKit
import Foundation

/// One picture-in-picture: a renderer, its floating panel, and the capture
/// session feeding it. Everything here is per-PiP; the set of PiPs and
/// app-wide click-through live in `PiPManager`, while the status item,
/// activation policy, termination, and hot key stay in `AppController`.
@MainActor
final class PiPSession {
  /// Last published state. A renderer failure overrides every capture state
  /// because nothing can be displayed without a renderer.
  private(set) var state: CaptureState
  /// Rotation is display-only and session-scoped: it is not persisted and
  /// survives choosing another window.
  private(set) var rotation: VideoRotation = .none
  /// Capture frame rate; survives choosing another window.
  private(set) var frameRate: FrameRate
  /// Panel opacity, always within `AppSettings.opacityRange`.
  private(set) var opacity: Double
  private(set) var isClickThrough = false
  /// True from `show()` (or any action that brings the panel up) until the
  /// panel closes. A closed panel always has its capture stopped.
  private(set) var isPanelOpen = false
  private var isClosed = false
  private var operationID: UInt64 = 0
  private var stopRequested = false
  private var stoppedByUser = false
  private var didNotifyClose = false
  private var retainedSource: SourceIdentity?
  private var retainedCrop: CGRect?
  private var pendingResumeCrop: CGRect?
  private var resumeOperation: UInt64?
  private struct RestoreSelection {
    let setup: SavedSetup
    var operation: UInt64
    var selectedSource: SourceIdentity?
    var previewReady = false
  }
  private var restoreSelection: RestoreSelection?
  private var selectionIssue: SelectionIssue?

  var hasRetainedSetup: Bool { !isClosed && retainedSource != nil }
  var isStoppingCapture: Bool { stopRequested }
  var isPausedByUser: Bool { stoppedByUser }
  var canChooseSource: Bool {
    !isClosed && !isShuttingDown && !stopRequested && renderer != nil
  }
  var hasCaptureWork: Bool {
    stopRequested || captureSession.hasCaptureWork || pickTask != nil || isSelecting
  }
  private var isSelecting: Bool {
    if case .selecting = state { return true }
    return false
  }
  private var isRunning: Bool {
    if case .running = state { return true }
    return false
  }
  var canResumeCapture: Bool {
    !isClosed && !isShuttingDown && !stopRequested && renderer != nil
      && retainedSource != nil && !hasCaptureWork
  }
  var canOpenSourceApp: Bool {
    !isClosed && !isShuttingDown && retainedSource?.isSameRunningApplication() == true
  }
  var canRememberSetup: Bool {
    !isClosed && !isShuttingDown && renderer != nil && captureSession.hasCaptureWork
      && captureSession.sourceIdentity != nil && isRunning
  }
  var canApplySavedSetup: Bool {
    !isClosed && !isShuttingDown && captureSession.hasCaptureWork && isRunning
      && ((restoreSelection?.previewReady == true
        && captureSession.sourceIdentity == restoreSelection?.selectedSource)
        || pendingResumeCrop != nil)
  }
  var hasPendingResumeRegion: Bool { pendingResumeCrop != nil }
  /// Menu label: the current or last source title, or "Empty" once the
  /// panel was closed or before any source started.
  var displayTitle: String {
    lastSourceTitle ?? L10n.string("menu.emptyPiP")
  }

  /// Current panel frame, used to cascade a new PiP from this one.
  var panelFrame: NSRect {
    panelController.frame
  }

  /// Captured region of the source window, normalized with a top-left origin
  /// in source orientation; `nil` captures the whole window. Reset whenever a
  /// new source starts.
  var crop: CGRect? {
    captureSession.crop
  }

  /// Region selection is only meaningful while frames are displayed.
  var canSelectRegion: Bool {
    guard !isClosed, !isShuttingDown, !stopRequested, renderer != nil else { return false }
    switch state {
    case .running, .suspended:
      return true
    case .idle, .selecting, .starting, .stopped, .failed:
      return false
    }
  }

  var onStateChange: ((CaptureState) -> Void)?
  /// Fired after the panel close path requested a capture stop (user close,
  /// `close()`, or auto-close on source close).
  var onPanelClosed: (() -> Void)?

  private let settings: AppSettings
  private let renderer: FrameRenderer?
  private let panelController: FloatingPanelController
  private let captureSession: CaptureSession
  private let rendererFailure: String?
  /// Set synchronously by `beginShutdown()` so panel-originated actions are
  /// suppressed from the moment termination starts, before the async
  /// `shutdown()` gets to run.
  private var isShuttingDown = false
  /// Whether the in-panel window list is shown. It is shown exactly while the
  /// published state is idle, stopped, or failed (and a renderer exists).
  private var isSourceChooserVisible = false
  private var windowListTask: Task<Void, Never>?
  private var pickTask: Task<Void, Never>?
  /// Set when a window was picked "with region": crop selection starts as soon
  /// as that capture reports running. Cleared by any other outcome.
  private var pendingRegionSelection = false
  /// Compacted title of the last source that reached `.running`.
  private var lastSourceTitle: String?

  /// `autosaveName` keys the remembered panel frame; `cascadeFrom` places a
  /// panel that has no remembered frame next to an existing one.
  init(settings: AppSettings, autosaveName: String, cascadeFrom: NSRect?) {
    self.settings = settings
    frameRate = settings.defaultFrameRate
    opacity = Self.clampOpacity(settings.defaultOpacity)

    let candidateRenderer: FrameRenderer?
    let failure: String?
    do {
      candidateRenderer = try FrameRenderer()
      failure = nil
    } catch {
      candidateRenderer = nil
      let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
      failure =
        detail.isEmpty
        ? L10n.string("renderer.unavailable") : L10n.format("renderer.error", detail)
    }
    renderer = candidateRenderer
    rendererFailure = failure

    let videoView: NSView
    if let candidateRenderer {
      videoView = candidateRenderer.view
    } else {
      let fallbackView = NSView(frame: .zero)
      fallbackView.wantsLayer = true
      fallbackView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
      videoView = fallbackView
    }
    panelController = FloatingPanelController(videoView: videoView, autosaveName: autosaveName)
    if let cascadeFrom {
      panelController.cascade(from: cascadeFrom)
    }

    captureSession = CaptureSession(
      onFrame: { frame in
        candidateRenderer?.submit(frame)
      },
      onReset: { generation in
        candidateRenderer?.reset(generation: generation)
      }
    )
    state = failure.map { CaptureState.failed($0) } ?? .idle

    configurePanelCallbacks()
    candidateRenderer?.onContentSizeChange = { [weak self] size in
      self?.panelController.setSourceAspect(size)
    }
    captureSession.onStateChange = { [weak self] state in
      self?.captureStateChanged(state)
    }
    captureSession.onSourceWindowClosed = { [weak self] in
      self?.sourceWindowClosed()
    }
    captureSession.onSourceAccepted = { [weak self] source in
      guard let self, !self.isClosed, !self.isShuttingDown, !self.stopRequested else { return }
      self.retainedSource = source
      self.stoppedByUser = false
      self.selectionIssue = nil
      if self.resumeOperation != self.operationID { self.retainedCrop = nil }
      self.resumeOperation = nil
      if self.restoreSelection?.operation == self.operationID {
        self.restoreSelection?.selectedSource = source
        self.restoreSelection?.previewReady = false
      } else {
        self.restoreSelection = nil
      }
      self.panelController.setSelectionNotice(nil)
      self.onStateChange?(self.state)
    }
    captureSession.onSelectionIssue = { [weak self] issue in
      guard let self, !self.isClosed, !self.isShuttingDown else { return }
      self.restoreSelection = nil
      self.presentSelectionIssue(issue)
    }

    captureSession.setFrameRate(frameRate)
    panelController.setOpacity(opacity)
    updateCaptureOutputSize(videoPixelSize: panelController.videoPixelSize)
    panelController.update(state: state)
  }

  /// Showing a hidden panel never authorizes or restarts capture.
  func show() {
    guard !isClosed, !isShuttingDown else { return }
    showPanel()
    if wantsSourceChooser { presentIdleChooser() }
  }

  func hide() {
    guard !isClosed, !isShuttingDown else { return }
    stopCapture()
    isPanelOpen = false
    panelController.hide()
  }

  /// Close is terminal, including when the panel was already hidden.
  func close() {
    guard !isClosed else { return }
    isClosed = true
    stopCapture()
    retainedSource = nil
    retainedCrop = nil
    pendingResumeCrop = nil
    lastSourceTitle = nil
    isPanelOpen = false
    panelController.close()
    // `close()` on an already hidden panel need not invoke the view callback.
    notifyPanelClosedOnce()
  }

  func chooseWindow() {
    beginPicker(keepRestore: false)
  }

  private func beginPicker(keepRestore: Bool) {
    guard !isClosed, !isShuttingDown, !stopRequested else { return }
    guard renderer != nil else {
      showRendererFailure()
      return
    }
    operationID &+= 1
    resumeOperation = nil
    stopRequested = false
    selectionIssue = nil
    if !keepRestore { restoreSelection = nil }
    pendingResumeCrop = nil
    pendingRegionSelection = false
    pickTask?.cancel()
    pickTask = nil
    showPanel()
    panelController.setSelectionNotice(nil)
    captureSession.chooseWindow()
  }

  /// Starts (or replaces) the capture with a window from the in-app list. With
  /// `region`, crop selection begins once the capture is running.
  /// Resolves a list selection again, discarding results from older operations.
  func pickWindow(_ windowID: CGWindowID, region: Bool) {
    guard !isClosed, !isShuttingDown, !stopRequested else { return }
    guard renderer != nil else {
      showRendererFailure()
      return
    }
    showPanel()
    operationID &+= 1
    resumeOperation = nil
    stopRequested = false
    let operation = operationID
    // A restore flow intentionally accepts its own next list pick; all other
    // list picks, including region picks, are ordinary selections.
    if region || restoreSelection?.selectedSource != nil { restoreSelection = nil }
    restoreSelection?.operation = operation
    pendingResumeCrop = nil
    pendingRegionSelection = false
    pickTask?.cancel()
    pickTask = Task { @MainActor [weak self] in
      do {
        let resolved = try await WindowCatalog.makeFilter(for: windowID)
        guard let self, !Task.isCancelled, !self.isClosed, !self.isShuttingDown,
          self.operationID == operation
        else { return }
        self.pickTask = nil
        self.pendingRegionSelection = region
        self.captureSession.start(filter: resolved.filter, title: resolved.window.displayTitle)
      } catch {
        guard let self, !Task.isCancelled, !self.isClosed, !self.isShuttingDown,
          self.operationID == operation
        else { return }
        self.pickTask = nil
        self.restoreSelection = nil
        self.handleCatalogError(error)
      }
    }
  }

  /// Reloads the in-panel window list. No-op while a capture is running.
  /// Optional window catalog; picker remains available without its permission.
  func refreshWindowList() {
    guard !isClosed, !isShuttingDown, isPanelOpen, wantsSourceChooser else { return }
    selectionIssue = nil
    windowListTask?.cancel()
    windowListTask = nil
    guard ScreenCapturePermission.isGranted else {
      setSourceChooser(.permissionRequired)
      return
    }
    setSourceChooser(.loading)
    windowListTask = Task { @MainActor [weak self] in
      let content: WindowListView.Content
      do {
        content = .windows(try await WindowCatalog.fetch())
      } catch WindowCatalogError.permissionDenied {
        content = .permissionRequired
      } catch {
        content = .failure(.catalogUnavailable)
      }
      guard let self, !Task.isCancelled, !self.isClosed, self.isPanelOpen,
        self.wantsSourceChooser
      else { return }
      self.windowListTask = nil
      self.setSourceChooser(content)
    }
  }

  func refreshSourceChooserIfVisible() {
    guard isPanelOpen, !isClosed, !isShuttingDown, wantsSourceChooser else { return }
    if retainedSource == nil { refreshWindowList() } else { presentIdleChooser() }
  }
  /// Resume only after fresh identity/permission proof; otherwise use user consent.
  func resumeCapture() {
    guard canResumeCapture, let source = retainedSource else { return }
    restoreSelection = nil
    if !ScreenCapturePermission.isGranted || !source.isSameRunningApplication() {
      beginPicker(keepRestore: false)
      return
    }
    operationID &+= 1
    resumeOperation = operationID
    stopRequested = false
    let operation = operationID
    showPanel()
    panelController.setSelectionNotice(nil)
    pickTask?.cancel()
    pickTask = Task { @MainActor [weak self] in
      do {
        let resolved = try await WindowCatalog.makeFilter(for: source)
        guard let self, !Task.isCancelled, !self.isClosed, !self.isShuttingDown,
          self.operationID == operation
        else { return }
        self.pickTask = nil
        guard let fresh = SourceIdentity.from(filter: resolved.filter),
          fresh.isSameRunningApplication()
        else {
          self.beginPicker(keepRestore: false)
          return
        }
        let unchanged = fresh.sourceSize == source.sourceSize
        let initialCrop = unchanged ? self.retainedCrop : nil
        self.pendingResumeCrop = unchanged ? nil : self.retainedCrop
        self.captureSession.start(
          filter: resolved.filter, title: resolved.window.displayTitle, initialCrop: initialCrop)
      } catch WindowCatalogError.permissionDenied {
        guard let self, !Task.isCancelled, self.operationID == operation else { return }
        self.pickTask = nil
        self.beginPicker(keepRestore: false)
      } catch WindowCatalogError.windowNotFound {
        guard let self, !Task.isCancelled, self.operationID == operation else { return }
        self.pickTask = nil
        self.beginPicker(keepRestore: false)
      } catch {
        guard let self, !Task.isCancelled, self.operationID == operation else { return }
        self.pickTask = nil
        self.presentSelectionIssue(.catalogUnavailable)
      }
    }
  }

  func openSourceApp() {
    guard canOpenSourceApp, let source = retainedSource,
      let app = NSRunningApplication(processIdentifier: source.processID),
      source.isSameRunningApplication(), app.activate(options: [])
    else {
      presentSelectionIssue(.sourceAppUnavailable)
      return
    }
  }

  func rememberCurrentSetup(in store: SavedSetupStore) {
    guard canRememberSetup, let source = captureSession.sourceIdentity,
      let setup = SavedSetup(
        appBundleIdentifier: source.bundleIdentifier, appName: source.appName,
        crop: captureSession.crop, sourceSize: source.sourceSize,
        frameRate: frameRate.rawValue, opacity: opacity, rotationDegrees: rotation.degrees),
      store.save(setup)
    else {
      presentSelectionIssue(.setupUnavailable)
      return
    }
    panelController.setSelectionNotice(nil)
  }

  func restoreSavedSetup(from store: SavedSetupStore) {
    guard !isClosed, !isShuttingDown, !stopRequested, renderer != nil else { return }
    guard let setup = store.savedSetup, setup.isValid else {
      presentSelectionIssue(.setupUnavailable)
      return
    }
    restoreSelection = RestoreSelection(setup: setup, operation: operationID &+ 1)
    beginPicker(keepRestore: true)
  }
  func forgetSavedSetup() {
    restoreSelection = nil
    onStateChange?(state)
  }

  func applySavedSetup() {
    guard canApplySavedSetup, let source = captureSession.sourceIdentity else { return }
    let setup = restoreSelection?.previewReady == true ? restoreSelection?.setup : nil
    guard setup?.isValid != false else {
      restoreSelection = nil
      presentSelectionIssue(.setupUnavailable)
      return
    }
    let alert = NSAlert()
    if let setup {
      alert.messageText = L10n.string("setup.confirmTitle")
      let mismatch =
        setup.sourceSize != source.sourceSize
        || (setup.appBundleIdentifier != nil
          && setup.appBundleIdentifier != source.bundleIdentifier)
        || setup.appName != source.appName
      alert.informativeText =
        L10n.format("setup.confirmMessage", source.appName)
        + (mismatch ? "\n\n" + L10n.format("setup.mismatchMessage", source.appName) : "")
    } else {
      alert.messageText = L10n.string("setup.resumeRegionConfirmTitle")
      alert.informativeText = L10n.format("setup.resumeRegionConfirmMessage", source.appName)
    }
    alert.addButton(
      withTitle: L10n.string(setup == nil ? "setup.applyPreviousRegion" : "setup.apply"))
    alert.addButton(withTitle: L10n.string("setup.cancel"))
    guard alert.runModal() == .alertFirstButtonReturn, !isClosed, !isShuttingDown,
      captureSession.sourceIdentity == source, canApplySavedSetup
    else { return }
    if let setup {
      guard let rate = FrameRate(rawValue: setup.frameRate),
        let newRotation = VideoRotation(rawValue: setup.rotationDegrees / 90)
      else {
        restoreSelection = nil
        presentSelectionIssue(.setupUnavailable)
        return
      }
      setFrameRate(rate)
      setOpacity(setup.opacity)
      setRotation(newRotation)
      captureSession.setCrop(setup.crop)
      restoreSelection = nil
    } else if let crop = pendingResumeCrop {
      captureSession.setCrop(crop)
      pendingResumeCrop = nil
    }
    onStateChange?(state)
  }

  private func setRotation(_ value: VideoRotation) {
    guard value != rotation else { return }
    let previous = rotation
    rotation = value
    if value.swapsDimensions != previous.swapsDimensions {
      panelController.swapVideoOrientation()
      updateCaptureOutputSize(videoPixelSize: panelController.videoPixelSize)
    }
    renderer?.setRotation(value)
  }

  /// Prompts for Screen Recording access (first time only) and falls back to
  /// System Settings when it is still denied.
  func requestScreenRecordingPermission() {
    guard !isShuttingDown else { return }
    if !ScreenCapturePermission.request() {
      ScreenCapturePermission.openSystemSettings()
    }
    refreshWindowList()
  }

  func setFrameRate(_ rate: FrameRate) {
    frameRate = rate
    captureSession.setFrameRate(rate)
  }

  func setOpacity(_ value: Double) {
    opacity = Self.clampOpacity(value)
    panelController.setOpacity(opacity)
  }

  /// Click-through ends any crop or size editing on the panel. Region
  /// selection is refused while it is on, so callers turn it off first.
  func setClickThrough(_ enabled: Bool) {
    isClickThrough = enabled
    panelController.setClickThrough(enabled)
  }

  /// Overlays the crop selection on the displayed video.
  func beginCrop() {
    guard !isShuttingDown, !isClickThrough, canSelectRegion else { return }
    showPanel()
    panelController.beginCropSelection()
  }

  func resetCrop() {
    guard !isClosed, !isShuttingDown else { return }
    if panelController.isCropping {
      panelController.cancelCropSelection()
    }
    retainedCrop = nil
    pendingResumeCrop = nil
    captureSession.setCrop(nil)
  }

  func rotate() {
    // A selection drawn in the old orientation would map to the wrong pixels.
    if panelController.isCropping {
      panelController.cancelCropSelection()
    }
    let previous = rotation
    let next = previous.next
    // Update the rotation first: the panel swap emits a new video pixel size,
    // and the capture target must be derived with the new orientation.
    rotation = next
    if next.swapsDimensions != previous.swapsDimensions {
      panelController.swapVideoOrientation()
      updateCaptureOutputSize(videoPixelSize: panelController.videoPixelSize)
    }
    renderer?.setRotation(next)
  }

  func applyPreset(videoWidth: CGFloat) {
    showPanel()
    panelController.applyPreset(videoWidth: videoWidth)
  }

  func beginCustomSizeEditing() {
    // The panel ignores size editing during click-through; showing it would
    // only bring a hidden PiP back without an editor.
    guard !isShuttingDown, !isClickThrough else { return }
    show()
    panelController.beginCustomSizeEditing()
  }

  /// Invalidate every selection/restore operation before scheduling stop.
  func stopCapture() {
    operationID &+= 1
    stopRequested = true
    stoppedByUser = true
    selectionIssue = nil
    resumeOperation = nil
    if !isClosed, let identity = captureSession.sourceIdentity {
      retainedSource = identity
      retainedCrop = captureSession.crop
    }
    captureSession.invalidateForUserStop()
    pendingRegionSelection = false
    pendingResumeCrop = nil
    restoreSelection = nil
    pickTask?.cancel()
    pickTask = nil
    windowListTask?.cancel()
    windowListTask = nil
    let stoppedOperation = operationID
    Task { @MainActor [weak self] in
      guard let self else { return }
      await self.captureSession.stop()
      guard !self.isClosed, !self.isShuttingDown,
        self.operationID == stoppedOperation
      else { return }
      self.stopRequested = false
      self.presentIdleChooser()
      self.onStateChange?(self.state)
    }
    onStateChange?(state)
  }

  func beginShutdown() {
    guard !isShuttingDown else { return }
    stopCapture()
    isShuttingDown = true
  }

  func shutdown() async {
    beginShutdown()
    await captureSession.stop()
    renderer?.shutdown()
  }

  private func configurePanelCallbacks() {
    panelController.onChooseWindow = { [weak self] in
      self?.chooseWindow()
    }
    panelController.onUseSystemPicker = { [weak self] in
      self?.chooseWindow()
    }
    panelController.onPickWindow = { [weak self] windowID in
      self?.pickWindow(windowID, region: false)
    }
    panelController.onPickWindowRegion = { [weak self] windowID in
      self?.pickWindow(windowID, region: true)
    }
    panelController.onResumeCapture = { [weak self] in
      self?.resumeCapture()
    }
    panelController.onRefreshWindowList = { [weak self] in
      self?.refreshWindowList()
    }
    panelController.onRequestPermission = { [weak self] in
      self?.requestScreenRecordingPermission()
    }
    panelController.onBeginCrop = { [weak self] in
      self?.beginCrop()
    }
    panelController.onCropSelection = { [weak self] result in
      self?.cropSelectionFinished(result)
    }
    panelController.onClose = { [weak self] in
      self?.panelDidClose()
    }
    panelController.onVideoPixelSizeChange = { [weak self] size in
      self?.updateCaptureOutputSize(videoPixelSize: size)
    }
  }

  private var wantsSourceChooser: Bool {
    guard renderer != nil, !isClosed, !isShuttingDown, !stopRequested else { return false }
    switch state {
    case .idle, .stopped, .failed:
      return !captureSession.hasCaptureWork
    case .selecting, .starting, .running, .suspended:
      return false
    }
  }

  private func presentIdleChooser() {
    guard isPanelOpen, wantsSourceChooser else { return }
    if let selectionIssue {
      setSourceChooser(.failure(selectionIssue))
    } else if let retainedSource {
      setSourceChooser(.paused(source: retainedSource.appName, canResume: canResumeCapture))
    } else {
      refreshWindowList()
    }
  }

  private func handleCatalogError(_ error: any Error) {
    if case WindowCatalogError.permissionDenied = error {
      if wantsSourceChooser {
        setSourceChooser(.permissionRequired)
      } else {
        presentSelectionIssue(.catalogUnavailable)
      }
    } else if case WindowCatalogError.windowNotFound = error {
      presentSelectionIssue(.sourceUnavailable)
    } else {
      presentSelectionIssue(.catalogUnavailable)
    }
  }

  private func presentSelectionIssue(_ issue: SelectionIssue) {
    selectionIssue = issue
    if wantsSourceChooser, isPanelOpen {
      setSourceChooser(.failure(issue))
    } else {
      panelController.setSelectionNotice(issue)
    }
    onStateChange?(state)
  }

  private func setSourceChooser(_ content: WindowListView.Content?) {
    isSourceChooserVisible = content != nil
    panelController.setSourceChooser(content)
  }

  private func showRendererFailure() {
    if let rendererFailure {
      panelController.update(state: .failed(rendererFailure))
    }
    showPanel()
  }

  /// The panel reports a rect normalized to the displayed video, which is
  /// rotated and already cropped. Rotate it back into source orientation, then
  /// express it inside the current crop so repeated selections zoom further.
  private func cropSelectionFinished(_ result: CropSelectionView.Result) {
    guard !isShuttingDown else { return }
    switch result {
    case .apply(let displayRect):
      let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
      let selection = rotation.sourceRect(fromDisplayRect: displayRect).intersection(unit)
      guard !selection.isNull, selection.width > 0, selection.height > 0 else { return }
      let base = captureSession.crop ?? unit
      let composed = CGRect(
        x: base.minX + selection.minX * base.width,
        y: base.minY + selection.minY * base.height,
        width: selection.width * base.width,
        height: selection.height * base.height
      ).intersection(unit)
      guard !composed.isNull, composed.width > 0, composed.height > 0 else { return }
      captureSession.setCrop(composed)
    case .reset:
      captureSession.setCrop(nil)
    case .cancel:
      break
    }
  }

  /// The capture stream is never rotated, so a quarter-turn display rotation
  /// maps the panel's video width onto the source height and vice versa.
  private func updateCaptureOutputSize(videoPixelSize size: CGSize) {
    let target =
      rotation.swapsDimensions ? CGSize(width: size.height, height: size.width) : size
    captureSession.updateOutputSize(target)
  }

  private func showPanel() {
    guard !isClosed, !isShuttingDown else { return }
    isPanelOpen = true
    panelController.show()
  }

  private func notifyPanelClosedOnce() {
    guard !didNotifyClose else { return }
    didNotifyClose = true
    onPanelClosed?()
  }

  private func panelDidClose() {
    close()
  }

  private func sourceWindowClosed() {
    guard !isClosed, !isShuttingDown else { return }
    if settings.autoCloseOnSourceClose {
      close()
    } else {
      stoppedByUser = false
      presentSelectionIssue(.sourceUnavailable)
    }
  }

  private func captureStateChanged(_ state: CaptureState) {
    guard !isClosed, !isShuttingDown else { return }
    let wasSelecting = isSelecting
    if stopRequested {
      guard case .stopped = state else { return }
    }
    switch state {
    case .idle, .stopped, .failed:
      panelController.setSourceAspect(nil)
      pendingRegionSelection = false
    case .selecting, .starting, .running, .suspended:
      break
    }

    let published = rendererFailure.map { CaptureState.failed($0) } ?? state
    self.state = published
    if case .running(let title) = published {
      lastSourceTitle = Self.menuTitle(title)
      if restoreSelection?.selectedSource == captureSession.sourceIdentity {
        restoreSelection?.previewReady = true
      }
    }
    if case .selecting = state {
      // The picker still owns the pending restore.
    } else if restoreSelection?.selectedSource == nil, restoreSelection != nil,
      pickTask == nil
    {
      restoreSelection = nil
    }
    panelController.update(state: published)

    switch published {
    case .starting, .running, .suspended:
      if isSourceChooserVisible || windowListTask != nil {
        windowListTask?.cancel()
        windowListTask = nil
        setSourceChooser(nil)
      }
      if pendingRegionSelection, case .running = published {
        pendingRegionSelection = false
        beginCrop()
      }
    case .idle, .stopped, .failed:
      if panelController.isCropping {
        panelController.cancelCropSelection()
      }
      if isPanelOpen, wantsSourceChooser {
        if retainedSource != nil || !isSourceChooserVisible || wasSelecting {
          presentIdleChooser()
        }
      }
    case .selecting:
      // The system picker is open; whatever the panel shows stays underneath.
      if panelController.isCropping {
        panelController.cancelCropSelection()
      }
    }
    if case .failed = state, restoreSelection != nil {
      restoreSelection = nil
      presentSelectionIssue(.sourceUnavailable)
    }

    onStateChange?(published)
  }

  private static func clampOpacity(_ value: Double) -> Double {
    guard value.isFinite else { return AppSettings.opacityRange.upperBound }
    return min(max(value, AppSettings.opacityRange.lowerBound), AppSettings.opacityRange.upperBound)
  }

  private static func menuTitle(_ value: String) -> String? {
    let compact =
      value
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !compact.isEmpty else { return nil }
    return compact.count > 60 ? String(compact.prefix(59)) + "…" : compact
  }
}
