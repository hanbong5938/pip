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
    guard renderer != nil else { return false }
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

    captureSession.setFrameRate(frameRate)
    panelController.setOpacity(opacity)
    updateCaptureOutputSize(videoPixelSize: panelController.videoPixelSize)
    panelController.update(state: state)
  }

  /// Shows the panel; while no capture runs, the window list is refreshed so
  /// it is current every time the panel comes back.
  func show() {
    showPanel()
    if wantsSourceChooser {
      refreshWindowList()
    }
  }

  /// Hides the panel through the same path as its close button, which stops
  /// the capture and fires `onPanelClosed`. No-op while already closed.
  func close() {
    panelController.close()
  }

  /// Opens the system window picker (`SCContentSharingPicker`).
  func chooseWindow() {
    guard !isShuttingDown else { return }
    guard renderer != nil else {
      showRendererFailure()
      return
    }

    pendingRegionSelection = false
    pickTask?.cancel()
    pickTask = nil
    showPanel()
    captureSession.chooseWindow()
  }

  /// Starts (or replaces) the capture with a window from the in-app list. With
  /// `region`, crop selection begins once the capture is running.
  func pickWindow(_ windowID: CGWindowID, region: Bool) {
    guard !isShuttingDown else { return }
    guard renderer != nil else {
      showRendererFailure()
      return
    }

    showPanel()
    pendingRegionSelection = false
    pickTask?.cancel()
    pickTask = Task { @MainActor [weak self] in
      do {
        let resolved = try await WindowCatalog.makeFilter(for: windowID)
        guard let self, !Task.isCancelled, !self.isShuttingDown else { return }
        self.pickTask = nil
        self.pendingRegionSelection = region
        self.captureSession.start(filter: resolved.filter, title: resolved.window.displayTitle)
      } catch {
        guard let self, !Task.isCancelled, !self.isShuttingDown else { return }
        self.pickTask = nil
        if case WindowCatalogError.permissionDenied = error, self.wantsSourceChooser {
          self.windowListTask?.cancel()
          self.windowListTask = nil
          self.setSourceChooser(.permissionRequired)
        } else {
          // The listed window is gone (or ScreenCaptureKit hiccupped); show
          // what is capturable now. No-op while another capture runs.
          self.refreshWindowList()
        }
      }
    }
  }

  /// Reloads the in-panel window list. No-op while a capture is running.
  func refreshWindowList() {
    guard !isShuttingDown, wantsSourceChooser else { return }
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
        content = .windows([])
      }
      guard let self, !Task.isCancelled, self.wantsSourceChooser else { return }
      self.windowListTask = nil
      self.setSourceChooser(content)
    }
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
    guard !isShuttingDown else { return }
    if panelController.isCropping {
      panelController.cancelCropSelection()
    }
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

  /// Fire-and-forget capture stop.
  func stopCapture() {
    pendingRegionSelection = false
    pickTask?.cancel()
    pickTask = nil
    Task { @MainActor [weak self] in
      guard let self else { return }
      await self.captureSession.stop()
    }
  }

  /// Suppresses panel-originated actions (choose window, close-driven stop)
  /// immediately. Call synchronously when termination begins; `shutdown()`
  /// runs later on a task.
  func beginShutdown() {
    isShuttingDown = true
    pendingRegionSelection = false
    pickTask?.cancel()
    pickTask = nil
    windowListTask?.cancel()
    windowListTask = nil
  }

  /// Awaits the capture stop, then shuts the renderer down.
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
    guard renderer != nil else { return false }
    switch state {
    case .idle, .stopped, .failed:
      return true
    case .selecting, .starting, .running, .suspended:
      return false
    }
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
    isPanelOpen = true
    panelController.show()
  }

  private func panelDidClose() {
    isPanelOpen = false
    lastSourceTitle = nil
    guard !isShuttingDown else { return }
    stopCapture()
    onPanelClosed?()
  }

  /// The capture session has already stopped and published why; auto-close
  /// takes the same path as the user closing the panel.
  private func sourceWindowClosed() {
    guard !isShuttingDown, settings.autoCloseOnSourceClose else { return }
    panelController.close()
  }

  private func captureStateChanged(_ state: CaptureState) {
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
      if wantsSourceChooser, !isSourceChooserVisible {
        refreshWindowList()
      }
    case .selecting:
      // The system picker is open; whatever the panel shows stays underneath.
      if panelController.isCropping {
        panelController.cancelCropSelection()
      }
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
