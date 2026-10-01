import AppKit

@MainActor
private final class PiPPanel: NSPanel {
  var onCloseRequested: (() -> Void)?

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  // Keep the panel alive so that a later show() reuses the same window.
  // Closing is intentionally an order-out operation; ownership of capture
  // and application shutdown remains with AppController.
  override func close() {
    onCloseRequested?()
  }
}

/// Content view that reports pointer hover over the whole content area. The
/// tracking area is `.activeAlways`, so hover is reported while the
/// nonactivating panel is not key and the application is inactive.
@MainActor
private final class HoverTrackingView: NSView {
  var onMouseEntered: (() -> Void)?
  var onMouseMoved: (() -> Void)?
  var onMouseExited: (() -> Void)?
  private var hoverTrackingArea: NSTrackingArea?

  override var acceptsFirstResponder: Bool { false }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard hoverTrackingArea == nil else { return }
    // `.inVisibleRect` keeps the area matched to the visible bounds, so it
    // is installed once and never needs updateTrackingAreas.
    let area = NSTrackingArea(
      rect: .zero,
      options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(area)
    hoverTrackingArea = area
  }

  // Subviews forward their own tracking events up the responder chain;
  // only this view's area describes the pointer entering or leaving the panel.
  override func mouseEntered(with event: NSEvent) {
    guard event.trackingArea === hoverTrackingArea else { return super.mouseEntered(with: event) }
    onMouseEntered?()
  }

  override func mouseMoved(with event: NSEvent) {
    onMouseMoved?()
  }

  override func mouseExited(with event: NSEvent) {
    guard event.trackingArea === hoverTrackingArea else { return super.mouseExited(with: event) }
    onMouseExited?()
  }
}

/// Hosts the video view and the views layered over it (source chooser, crop
/// selection). Reports every layout pass so overlays that depend on the
/// container size can follow live resizes.
@MainActor
private final class VideoContainerView: NSView {
  var onLayout: (() -> Void)?

  override var acceptsFirstResponder: Bool { false }

  override func layout() {
    super.layout()
    onLayout?()
  }
}

@MainActor
final class FloatingPanelController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
  var onChooseWindow: (() -> Void)?
  var onClose: (() -> Void)?
  var onVideoPixelSizeChange: ((CGSize) -> Void)?
  var onPickWindow: ((CGWindowID) -> Void)?
  var onPickWindowRegion: ((CGWindowID) -> Void)?
  var onRefreshWindowList: (() -> Void)?
  var onUseSystemPicker: (() -> Void)?
  var onRequestPermission: (() -> Void)?
  /// The overlay crop button was pressed.
  var onBeginCrop: (() -> Void)?
  /// A crop selection finished by the user (never fired for
  /// `cancelCropSelection()` or an automatic end).
  var onCropSelection: ((CropSelectionView.Result) -> Void)?

  /// Smallest content (video) area. The video fills the content view, so
  /// this is also the smallest video area.
  private static let minimumContentSize = NSSize(width: 240, height: 160)
  private static let overlayFadeInDuration: TimeInterval = 0.15
  private static let overlayFadeOutDuration: TimeInterval = 0.3
  private static let overlayHideDelay: Duration = .milliseconds(1500)

  private let panel: PiPPanel
  private let rootView: HoverTrackingView
  private let videoView: NSView
  private let videoContainer: VideoContainerView
  /// Hover HUD floating over the bottom of the video. It is not part of the
  /// sizing layout: the video always fills the content view.
  private let overlay: NSVisualEffectView
  private let statusLabel: NSTextField
  private let chooseWindowButton: NSButton
  private let cropButton: NSButton
  private let closeButton: NSButton
  private let controls: NSStackView
  private let sizeEditor: NSStackView
  private let widthField: NSTextField
  private let heightField: NSTextField
  private let applySizeButton: NSButton
  private let cancelSizeButton: NSButton
  private let clickThroughBadge: NSVisualEffectView
  private var windowListView: WindowListView?
  private var cropView: CropSelectionView?
  private weak var responderBeforeCrop: NSResponder?
  private var closeCallbackDelivered = false
  /// Unclamped video-area size and panel center requested by the last
  /// rotation swap, paired with the frame that swap produced. The size stays
  /// valid while the panel keeps that size and the center while it keeps that
  /// whole frame; any other resize or move falls back to measuring.
  private var rotationSizing: (videoSize: NSSize, center: NSPoint, appliedFrame: NSRect)?
  /// Captured source aspect (width / height) in source orientation.
  private var sourceAspect: CGFloat?
  /// True while a 90°/270° display rotation exchanges the video's width and height.
  private var isOrientationSwapped = false
  private var lastEmittedVideoPixelSize: CGSize?
  private var isEditingSize = false
  private var isSyncingSizeFields = false
  /// True while the last published state is `.running` or `.suspended`.
  private var isCapturing = false
  private var isClickThrough = false
  private var isPointerInside = false
  /// Target visibility of the overlay (its alpha may still be animating).
  private var isOverlayShown = true
  /// Bumped on every overlay visibility change so a stale fade-out
  /// completion cannot hide an overlay that was shown again meanwhile.
  private var overlayGeneration = 0
  private var overlayHideTask: Task<Void, Never>?
  /// Frame autosave name; each simultaneous PiP needs its own.
  private let autosaveName: String
  /// Whether a frame was saved under `autosaveName` before this panel
  /// existed; such a panel keeps its remembered frame instead of cascading.
  private let hasSavedFrame: Bool

  init(videoView: NSView, autosaveName: String = "pip.panel") {
    self.autosaveName = autosaveName
    self.hasSavedFrame =
      UserDefaults.standard.object(forKey: "NSWindow Frame \(autosaveName)") != nil
    self.videoView = videoView
    self.rootView = HoverTrackingView()
    self.videoContainer = VideoContainerView()
    self.overlay = NSVisualEffectView()

    let initialFrame = Self.initialFrame()
    self.panel = PiPPanel(
      contentRect: initialFrame,
      styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
      backing: .buffered,
      defer: true
    )
    self.statusLabel = NSTextField(labelWithString: L10n.string("state.idle"))
    self.chooseWindowButton = NSButton(frame: .zero)
    self.cropButton = NSButton(frame: .zero)
    self.closeButton = NSButton(frame: .zero)
    self.controls = NSStackView()
    self.sizeEditor = NSStackView()
    self.widthField = NSTextField(string: "")
    self.heightField = NSTextField(string: "")
    self.applySizeButton = NSButton(frame: .zero)
    self.cancelSizeButton = NSButton(frame: .zero)
    self.clickThroughBadge = NSVisualEffectView()

    super.init()

    configurePanel()
    configureContent()
    configureScreenChangeObservation()
    update(state: .idle)
  }

  deinit {
    let notificationCenter = NotificationCenter.default
    notificationCenter.removeObserver(
      self,
      name: NSApplication.didChangeScreenParametersNotification,
      object: nil
    )
    notificationCenter.removeObserver(
      self,
      name: NSWindow.didChangeOcclusionStateNotification,
      object: panel
    )
    NSWorkspace.shared.notificationCenter.removeObserver(
      self,
      name: NSWorkspace.activeSpaceDidChangeNotification,
      object: nil
    )
  }

  func show() {
    closeCallbackDelivered = false
    repositionIfNeeded()

    // Do not activate the application or make this panel key. A
    // nonactivating panel can still deliver clicks to its buttons.
    panel.orderFront(nil)
    requestVideoRedraw()
  }

  /// Hides the panel through the same once-only path as the close buttons.
  func close() {
    requestClose()
  }

  /// Current panel frame in screen coordinates.
  var frame: NSRect {
    panel.frame
  }

  /// Places the panel with its top-right corner 24pt down-left of `frame`'s,
  /// keeping its own size, constrained to the screen hosting `frame`. No-op
  /// when this panel restored a saved frame.
  func cascade(from frame: NSRect) {
    guard !hasSavedFrame, !frame.isEmpty else { return }
    let size = panel.frame.size
    var cascaded = NSRect(
      x: frame.maxX - 24 - size.width,
      y: frame.maxY - 24 - size.height,
      width: size.width,
      height: size.height
    )
    if let screen = Self.hostScreen(for: frame) {
      cascaded = Self.constrainedFrame(cascaded, to: screen.visibleFrame)
    }
    panel.setFrame(cascaded, display: panel.isVisible)
    emitVideoPixelSizeIfChanged()
  }

  /// Exchanges the width and height of the video area for a 90°/270° display
  /// rotation, keeping the panel's chrome, center, and on-screen placement.
  /// The requested size is remembered before the minSize clamp so that
  /// rotating back restores the original panel size exactly.
  /// Works while the panel is hidden; only the frame is updated then.
  func swapVideoOrientation() {
    isOrientationSwapped.toggle()
    updateCropContentRect()
    panel.layoutIfNeeded()

    let currentFrame = panel.frame
    let measuredVideoSize = videoContainer.frame.size
    guard measuredVideoSize.width > 0, measuredVideoSize.height > 0 else {
      rotationSizing = nil
      return
    }
    let chromeWidth = currentFrame.width - measuredVideoSize.width
    let chromeHeight = currentFrame.height - measuredVideoSize.height

    let baseVideoSize: NSSize
    if let rotationSizing, rotationSizing.appliedFrame.size == currentFrame.size {
      baseVideoSize = rotationSizing.videoSize
    } else {
      baseVideoSize = measuredVideoSize
    }
    let center: NSPoint
    if let rotationSizing, rotationSizing.appliedFrame == currentFrame {
      center = rotationSizing.center
    } else {
      center = NSPoint(x: currentFrame.midX, y: currentFrame.midY)
    }
    let videoSize = NSSize(width: baseVideoSize.height, height: baseVideoSize.width)
    let size = NSSize(
      width: max(chromeWidth + videoSize.width, panel.minSize.width),
      height: max(chromeHeight + videoSize.height, panel.minSize.height)
    )

    var frame = NSRect(
      x: center.x - size.width / 2,
      y: center.y - size.height / 2,
      width: size.width,
      height: size.height
    )
    if let screen = Self.hostScreen(for: frame) {
      frame = Self.constrainedFrame(frame, to: screen.visibleFrame)
    }

    panel.setFrame(frame, display: panel.isVisible, animate: false)
    rotationSizing = (videoSize, center, panel.frame)
    requestVideoRedraw()
  }

  func update(state: CaptureState) {
    let presentation = Self.presentation(for: state)
    panel.title = presentation.title
    panel.setAccessibilityLabel(presentation.title)
    statusLabel.stringValue = presentation.status
    statusLabel.setAccessibilityValue(presentation.status)

    switch state {
    case .selecting, .starting:
      chooseWindowButton.isEnabled = false
    default:
      chooseWindowButton.isEnabled = true
    }

    switch state {
    case .running, .suspended:
      isCapturing = true
    default:
      isCapturing = false
    }
    cropButton.isEnabled = isCapturing
    if !isCapturing {
      cancelCropSelection()
    }
    refreshOverlay(animated: true)
  }

  /// Shows the panel and replaces the overlay's button row with an inline
  /// width × height editor for the video area, in points. Only the panel
  /// becomes key; the application is never activated. Ignored while
  /// click-through is on, since the panel cannot receive clicks then.
  func beginCustomSizeEditing() {
    guard !isClickThrough else { return }
    cancelCropSelection()
    show()
    isEditingSize = true
    controls.isHidden = true
    sizeEditor.isHidden = false
    // Unhides the overlay synchronously: hidden fields cannot take focus.
    refreshOverlay(animated: false)
    fillSizeFields()
    panel.makeKey()
    panel.makeFirstResponder(widthField)
    widthField.currentEditor()?.selectAll(nil)
  }

  /// Current video area size in backing pixels.
  var videoPixelSize: CGSize {
    panel.contentView?.layoutSubtreeIfNeeded()
    let size = videoContainer.bounds.size
    let scale = panel.backingScaleFactor
    return CGSize(
      width: (size.width * scale).rounded(),
      height: (size.height * scale).rounded()
    )
  }

  /// Aspect of the displayed video area: the source aspect, inverted while a
  /// quarter-turn display rotation is applied.
  private var displayAspect: CGFloat? {
    guard let sourceAspect else { return nil }
    return isOrientationSwapped ? 1 / sourceAspect : sourceAspect
  }

  /// Locks resizing to the given source aspect. `nil` (or a non-finite or
  /// non-positive size) restores free resizing without changing the frame.
  func setSourceAspect(_ size: CGSize?) {
    guard let size,
      size.width.isFinite, size.height.isFinite,
      size.width > 0, size.height > 0
    else {
      sourceAspect = nil
      updateCropContentRect()
      return
    }

    let aspect = size.width / size.height
    // Capture output sizes are whole pixels, so the reported aspect jitters
    // slightly whenever the output resolution follows the panel. Ignoring
    // sub-1% changes prevents a snap → reconfigure → snap feedback loop.
    if let existing = sourceAspect, abs(aspect - existing) / existing < 0.01 {
      return
    }
    sourceAspect = aspect
    updateCropContentRect()
    if isEditingSize {
      syncHeightFromWidthField()
    }

    // An in-progress drag picks the new aspect up in windowWillResize.
    guard !panel.inLiveResize else { return }

    guard let displayed = displayAspect else { return }
    let currentVideo = videoSize(forFrameSize: panel.frame.size)
    let videoWidth = currentVideo.width > 0 ? currentVideo.width : videoContainer.bounds.width
    let video = NSSize(width: videoWidth, height: videoWidth / displayed)
    setFrameAnchoringTopLeft(size: fittedFrameSize(forVideoSize: video))
  }

  /// Resizes the panel so its video area is `videoWidth` points wide.
  func applyPreset(videoWidth: CGFloat) {
    guard videoWidth.isFinite, videoWidth > 0 else { return }

    let aspect: CGFloat
    if let displayAspect {
      aspect = displayAspect
    } else {
      panel.contentView?.layoutSubtreeIfNeeded()
      let bounds = videoContainer.bounds.size
      if bounds.width > 0, bounds.height > 0 {
        aspect = bounds.width / bounds.height
      } else {
        aspect = 16.0 / 9.0
      }
    }

    let video = NSSize(width: videoWidth, height: videoWidth / aspect)
    setFrameAnchoringTopLeft(size: fittedFrameSize(forVideoSize: video))
  }

  // MARK: - Source chooser

  /// Shows the in-app window list over the video area (`content` non-nil)
  /// or removes it (`nil`, e.g. once a capture is running). While the list
  /// is shown the overlay carries the status only.
  func setSourceChooser(_ content: WindowListView.Content?) {
    guard let content else {
      guard let windowListView else { return }
      windowListView.removeFromSuperview()
      self.windowListView = nil
      updateOverlayControls()
      refreshOverlay(animated: true)
      return
    }

    cancelCropSelection()
    let listView = windowListView ?? makeWindowListView()
    listView.setContent(content)
    updateOverlayControls()
    refreshOverlay(animated: true)
  }

  private func makeWindowListView() -> WindowListView {
    let listView = WindowListView(frame: videoContainer.bounds)
    listView.translatesAutoresizingMaskIntoConstraints = false
    listView.onPick = { [weak self] windowID in self?.onPickWindow?(windowID) }
    listView.onPickRegion = { [weak self] windowID in self?.onPickWindowRegion?(windowID) }
    listView.onRefresh = { [weak self] in self?.onRefreshWindowList?() }
    listView.onUseSystemPicker = { [weak self] in self?.onUseSystemPicker?() }
    listView.onRequestPermission = { [weak self] in self?.onRequestPermission?() }
    // Above the video, below a crop selection.
    videoContainer.addSubview(listView, positioned: .above, relativeTo: videoView)
    pinToVideoContainer(listView)
    windowListView = listView
    return listView
  }

  // MARK: - Opacity and click-through

  /// Sets the whole panel's opacity, clamped to `AppSettings.opacityRange`;
  /// non-finite input means fully opaque.
  func setOpacity(_ value: Double) {
    let range = AppSettings.opacityRange
    let clamped = value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : range.upperBound
    panel.alphaValue = CGFloat(clamped)
  }

  /// While enabled the panel ignores the mouse entirely: size editing and
  /// crop selection end, the hover overlay is suppressed, and a small badge
  /// marks the mode.
  func setClickThrough(_ enabled: Bool) {
    guard enabled != isClickThrough else { return }
    isClickThrough = enabled
    if enabled {
      endSizeEditing()
      cancelCropSelection()
      isPointerInside = false
    }
    panel.ignoresMouseEvents = enabled
    clickThroughBadge.isHidden = !enabled
    refreshOverlay(animated: false)
  }

  // MARK: - Crop selection

  var isCropping: Bool { cropView != nil }

  /// Overlays a crop selection on the displayed video. Only the panel
  /// becomes key; the application is never activated. Ignored unless a
  /// capture is running or suspended and click-through is off.
  func beginCropSelection() {
    guard isCapturing, !isClickThrough else { return }
    if let cropView {
      cropView.begin()
      panel.makeKey()
      panel.makeFirstResponder(cropView)
      return
    }

    endSizeEditing()
    if !panel.isVisible {
      show()
    }

    let selection = CropSelectionView(frame: videoContainer.bounds)
    selection.translatesAutoresizingMaskIntoConstraints = false
    selection.onFinish = { [weak self, weak selection] result in
      guard let self, let selection else { return }
      self.finishCropSelection(from: selection, result: result)
    }
    videoContainer.addSubview(selection)
    pinToVideoContainer(selection)
    responderBeforeCrop = panel.firstResponder
    cropView = selection
    // A background drag must draw the selection, not move the panel.
    panel.isMovableByWindowBackground = false
    videoContainer.layoutSubtreeIfNeeded()
    updateCropContentRect()
    // The overlay would cover the bottom of the video while selecting.
    refreshOverlay(animated: false)

    selection.begin()
    panel.makeKey()
    panel.makeFirstResponder(selection)
  }

  /// Removes an active crop selection without reporting a result.
  func cancelCropSelection() {
    dismissCropSelection()
  }

  private func finishCropSelection(from selection: CropSelectionView, result: CropSelectionView.Result) {
    guard selection === cropView else { return }
    dismissCropSelection()
    onCropSelection?(result)
  }

  private func dismissCropSelection() {
    guard let selection = cropView else { return }
    cropView = nil
    selection.onFinish = nil
    let previousResponder = responderBeforeCrop
    responderBeforeCrop = nil
    selection.removeFromSuperview()
    panel.isMovableByWindowBackground = true

    if let previousResponder,
      previousResponder === panel || (previousResponder as? NSView)?.window === panel
    {
      panel.makeFirstResponder(previousResponder)
    } else {
      panel.makeFirstResponder(nil)
    }
    refreshOverlay(animated: true)
  }

  /// Keeps the selectable area on the letterboxed video: the renderer draws
  /// a centered aspect fit of the displayed aspect into the container.
  private func updateCropContentRect() {
    guard let cropView else { return }
    let rect = Self.aspectFitRect(aspect: displayAspect, in: cropView.bounds)
    if cropView.contentRect != rect {
      cropView.contentRect = rect
    }
  }

  private func pinToVideoContainer(_ view: NSView) {
    NSLayoutConstraint.activate([
      view.leadingAnchor.constraint(equalTo: videoContainer.leadingAnchor),
      view.trailingAnchor.constraint(equalTo: videoContainer.trailingAnchor),
      view.topAnchor.constraint(equalTo: videoContainer.topAnchor),
      view.bottomAnchor.constraint(equalTo: videoContainer.bottomAnchor),
    ])
  }

  // MARK: - Hover overlay

  /// The overlay is suppressed during click-through and crop selection. It
  /// is pinned visible while no capture is running, while the size editor or
  /// source chooser is open, and while VoiceOver runs (so its controls stay
  /// reachable). Otherwise it follows the pointer and fades out
  /// `overlayHideDelay` after the pointer leaves.
  private func refreshOverlay(animated: Bool) {
    if isClickThrough || cropView != nil {
      cancelOverlayHide()
      setOverlayShown(false, animated: false)
      return
    }

    let isPinned =
      !isCapturing || isEditingSize || windowListView != nil
      || NSWorkspace.shared.isVoiceOverEnabled
    if isPinned || isPointerInside {
      cancelOverlayHide()
      setOverlayShown(true, animated: animated)
    } else {
      scheduleOverlayHide()
    }
  }

  /// With the source chooser up the overlay is a status line only; the list
  /// itself offers every source action.
  private func updateOverlayControls() {
    let showsButtons = windowListView == nil
    chooseWindowButton.isHidden = !showsButtons
    cropButton.isHidden = !showsButtons
    closeButton.isHidden = !showsButtons
  }

  private func pointerDidEnterOrMove() {
    guard !isClickThrough else { return }
    isPointerInside = true
    refreshOverlay(animated: true)
  }

  private func pointerDidExit() {
    isPointerInside = false
    refreshOverlay(animated: true)
  }

  private func scheduleOverlayHide() {
    guard isOverlayShown, overlayHideTask == nil else { return }
    overlayHideTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: Self.overlayHideDelay)
      guard !Task.isCancelled, let self else { return }
      self.overlayHideTask = nil
      self.setOverlayShown(false, animated: true)
    }
  }

  private func cancelOverlayHide() {
    overlayHideTask?.cancel()
    overlayHideTask = nil
  }

  /// Fades the overlay; a hidden overlay is also `isHidden` so it neither
  /// takes clicks nor appears in the accessibility tree.
  private func setOverlayShown(_ shown: Bool, animated: Bool) {
    guard shown != isOverlayShown else { return }
    isOverlayShown = shown
    overlayGeneration &+= 1
    let generation = overlayGeneration

    if shown {
      overlay.isHidden = false
    }
    let duration =
      animated ? (shown ? Self.overlayFadeInDuration : Self.overlayFadeOutDuration) : 0
    NSAnimationContext.runAnimationGroup(
      { context in
        context.duration = duration
        self.overlay.animator().alphaValue = shown ? 1 : 0
      },
      completionHandler: { [weak self] in
        MainActor.assumeIsolated {
          guard let self, !shown, self.overlayGeneration == generation else { return }
          self.overlay.isHidden = true
        }
      }
    )
    if !shown && !animated {
      overlay.isHidden = true
    }
  }

  // MARK: - NSWindowDelegate

  func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
    guard let aspect = displayAspect else { return frameSize }

    let proposed = videoSize(forFrameSize: frameSize)
    let current = videoSize(forFrameSize: sender.frame.size)
    let widthChange = current.width > 0 ? abs(proposed.width - current.width) / current.width : 0
    let heightChange =
      current.height > 0 ? abs(proposed.height - current.height) / current.height : 0

    let video: NSSize
    if heightChange > widthChange {
      video = NSSize(width: proposed.height * aspect, height: proposed.height)
    } else {
      video = NSSize(width: proposed.width, height: proposed.width / aspect)
    }
    return fittedFrameSize(forVideoSize: video, on: sender.screen)
  }

  func windowDidResize(_ notification: Notification) {
    guard !panel.inLiveResize else { return }
    emitVideoPixelSizeIfChanged()
  }

  func windowDidEndLiveResize(_ notification: Notification) {
    emitVideoPixelSizeIfChanged()
    if isEditingSize {
      fillSizeFields()
    }
  }

  func windowDidChangeBackingProperties(_ notification: Notification) {
    emitVideoPixelSizeIfChanged()
  }

  // MARK: - NSTextFieldDelegate

  func controlTextDidChange(_ notification: Notification) {
    guard !isSyncingSizeFields, let aspect = displayAspect,
      let field = notification.object as? NSTextField,
      field === widthField || field === heightField,
      let value = validatedSizeValue(of: field)
    else { return }

    if field === widthField {
      setSizeFieldValue(heightField, linkedSizeValue(CGFloat(value) / aspect))
    } else {
      setSizeFieldValue(widthField, linkedSizeValue(CGFloat(value) * aspect))
    }
  }

  func control(
    _ control: NSControl,
    textView: NSTextView,
    doCommandBy commandSelector: Selector
  ) -> Bool {
    guard control === widthField || control === heightField else { return false }
    switch commandSelector {
    case #selector(NSResponder.insertNewline(_:)):
      applySizeEditing()
      return true
    case #selector(NSResponder.cancelOperation(_:)):
      endSizeEditing()
      return true
    default:
      return false
    }
  }

  private func configurePanel() {
    panel.isReleasedWhenClosed = false
    panel.level = .floating
    panel.hidesOnDeactivate = false
    panel.isFloatingPanel = true
    panel.becomesKeyOnlyIfNeeded = true
    panel.collectionBehavior = [
      .canJoinAllSpaces,
      .canJoinAllApplications,
      .fullScreenAuxiliary,
    ]
    panel.isMovableByWindowBackground = true
    panel.titleVisibility = .visible
    panel.titlebarAppearsTransparent = false
    panel.hasShadow = true
    panel.backgroundColor = .windowBackgroundColor
    panel.isOpaque = true
    panel.minSize = panel.frameRect(
      forContentRect: NSRect(origin: .zero, size: Self.minimumContentSize)
    ).size
    // Restores a saved frame (if any) immediately; initialFrame() covers
    // the first launch. show() re-homes frames from disconnected screens.
    _ = panel.setFrameAutosaveName(autosaveName)
    panel.delegate = self
    panel.setAccessibilityIdentifier("pip.panel")
    panel.setAccessibilityLabel(L10n.string("panel.accessibilityLabel"))

    panel.onCloseRequested = { [weak self] in
      self?.requestClose()
    }

    // Keep the standard title-bar close affordance, but route it through
    // the same once-only callback as the explicit content button.
    if let standardClose = panel.standardWindowButton(.closeButton) {
      standardClose.target = self
      standardClose.action = #selector(closeButtonPressed(_:))
      standardClose.setAccessibilityIdentifier("pip.titlebar.close")
      standardClose.setAccessibilityLabel(L10n.string("panel.close"))
    }
  }

  private func configureContent() {
    panel.contentView = rootView
    rootView.wantsLayer = true
    rootView.setAccessibilityIdentifier("pip.content")
    rootView.onMouseEntered = { [weak self] in self?.pointerDidEnterOrMove() }
    rootView.onMouseMoved = { [weak self] in self?.pointerDidEnterOrMove() }
    rootView.onMouseExited = { [weak self] in self?.pointerDidExit() }

    videoContainer.translatesAutoresizingMaskIntoConstraints = false
    videoContainer.wantsLayer = true
    videoContainer.layer?.backgroundColor = NSColor.black.cgColor
    videoContainer.setAccessibilityIdentifier("pip.video.container")
    videoContainer.setAccessibilityLabel(L10n.string("panel.video"))
    videoContainer.onLayout = { [weak self] in self?.updateCropContentRect() }

    videoView.translatesAutoresizingMaskIntoConstraints = false
    videoView.setAccessibilityIdentifier("pip.video")
    videoView.setAccessibilityLabel(L10n.string("panel.video"))
    videoContainer.addSubview(videoView)
    pinToVideoContainer(videoView)

    statusLabel.translatesAutoresizingMaskIntoConstraints = false
    statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    statusLabel.textColor = .labelColor
    statusLabel.alignment = .left
    statusLabel.lineBreakMode = .byTruncatingTail
    statusLabel.maximumNumberOfLines = 1
    statusLabel.isSelectable = false
    statusLabel.isEditable = false
    statusLabel.setAccessibilityIdentifier("pip.status")
    statusLabel.setAccessibilityLabel(L10n.string("panel.status"))
    // Never wider than its text; the first thing to truncate when the
    // overlay runs out of room.
    statusLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
    statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    configureIconButton(
      chooseWindowButton,
      symbol: "macwindow",
      label: L10n.string("panel.chooseWindow"),
      identifier: "pip.chooseWindow",
      action: #selector(chooseWindowButtonPressed(_:))
    )
    configureIconButton(
      cropButton,
      symbol: "crop",
      label: L10n.string("panel.crop"),
      identifier: "pip.crop",
      action: #selector(cropButtonPressed(_:))
    )
    cropButton.isEnabled = false
    configureIconButton(
      closeButton,
      symbol: "xmark",
      label: L10n.string("panel.close"),
      identifier: "pip.close",
      action: #selector(closeButtonPressed(_:))
    )

    for view in [statusLabel, chooseWindowButton, cropButton, closeButton] {
      controls.addArrangedSubview(view)
    }
    controls.translatesAutoresizingMaskIntoConstraints = false
    controls.orientation = .horizontal
    controls.alignment = .centerY
    controls.distribution = .fill
    controls.spacing = 6
    controls.setCustomSpacing(10, after: statusLabel)
    controls.setAccessibilityIdentifier("pip.controls")

    configureSizeField(
      widthField, identifier: "pip.size.width", label: L10n.string("panel.width"))
    configureSizeField(
      heightField, identifier: "pip.size.height", label: L10n.string("panel.height"))

    let timesLabel = NSTextField(labelWithString: "×")
    timesLabel.translatesAutoresizingMaskIntoConstraints = false
    timesLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    timesLabel.textColor = .secondaryLabelColor
    timesLabel.setAccessibilityElement(false)

    configureIconButton(
      applySizeButton,
      symbol: "checkmark.circle.fill",
      label: L10n.string("panel.apply"),
      identifier: "pip.size.apply",
      action: #selector(applySizeButtonPressed(_:))
    )
    // Palette keeps the checkmark legible inside the filled blue circle.
    applySizeButton.symbolConfiguration = NSImage.SymbolConfiguration(
      pointSize: 15, weight: .medium
    ).applying(NSImage.SymbolConfiguration(paletteColors: [.white, .systemBlue]))
    applySizeButton.keyEquivalent = "\r"

    configureIconButton(
      cancelSizeButton,
      symbol: "xmark.circle",
      label: L10n.string("panel.cancel"),
      identifier: "pip.size.cancel",
      action: #selector(cancelSizeButtonPressed(_:))
    )
    cancelSizeButton.keyEquivalent = "\u{1b}"

    for view in [widthField, timesLabel, heightField, applySizeButton, cancelSizeButton] {
      sizeEditor.addArrangedSubview(view)
    }
    sizeEditor.translatesAutoresizingMaskIntoConstraints = false
    sizeEditor.orientation = .horizontal
    sizeEditor.alignment = .centerY
    sizeEditor.distribution = .fill
    sizeEditor.spacing = 6
    sizeEditor.setCustomSpacing(10, after: heightField)
    sizeEditor.setAccessibilityIdentifier("pip.size.editor")
    sizeEditor.isHidden = true

    // Hidden rows are detached (NSStackView default), so the overlay hugs
    // whichever row is active.
    let overlayContent = NSStackView(views: [controls, sizeEditor])
    overlayContent.translatesAutoresizingMaskIntoConstraints = false
    overlayContent.orientation = .horizontal
    overlayContent.alignment = .centerY
    overlayContent.spacing = 0

    configureHUD(overlay)
    overlay.layer?.cornerRadius = 8
    overlay.setAccessibilityIdentifier("pip.overlay")
    overlay.setAccessibilityLabel(L10n.string("panel.controls"))
    overlay.addSubview(overlayContent)

    let badgeImage = NSImageView()
    badgeImage.translatesAutoresizingMaskIntoConstraints = false
    badgeImage.image = NSImage(
      systemSymbolName: "cursorarrow.click.2",
      accessibilityDescription: L10n.string("panel.clickThrough")
    )
    badgeImage.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
    badgeImage.contentTintColor = .labelColor
    badgeImage.setAccessibilityElement(false)

    configureHUD(clickThroughBadge)
    clickThroughBadge.layer?.cornerRadius = 11
    clickThroughBadge.alphaValue = 0.85
    clickThroughBadge.isHidden = true
    clickThroughBadge.setAccessibilityElement(true)
    clickThroughBadge.setAccessibilityRole(.image)
    clickThroughBadge.setAccessibilityIdentifier("pip.clickThroughBadge")
    clickThroughBadge.setAccessibilityLabel(L10n.string("panel.clickThrough"))
    clickThroughBadge.toolTip = L10n.string("panel.clickThrough")
    clickThroughBadge.addSubview(badgeImage)

    rootView.addSubview(videoContainer)
    rootView.addSubview(overlay)
    rootView.addSubview(clickThroughBadge)

    // Below NSLayoutConstraint.Priority.windowSizeStayPut (500): the
    // floating views may overflow a narrow panel but can never hold the
    // window open or resist a resize.
    let overlayFitPriority = NSLayoutConstraint.Priority(490)
    let overlayLeading = overlay.leadingAnchor.constraint(
      greaterThanOrEqualTo: rootView.leadingAnchor, constant: 8)
    overlayLeading.priority = overlayFitPriority
    let overlayTrailing = overlay.trailingAnchor.constraint(
      lessThanOrEqualTo: rootView.trailingAnchor, constant: -8)
    overlayTrailing.priority = overlayFitPriority

    // The video fills the whole content view, so there is no content chrome:
    // the overlay and badge float above it and take no part in sizing.
    NSLayoutConstraint.activate([
      videoContainer.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
      videoContainer.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
      videoContainer.topAnchor.constraint(equalTo: rootView.topAnchor),
      videoContainer.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
      videoContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),

      overlay.centerXAnchor.constraint(equalTo: rootView.centerXAnchor),
      overlay.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -8),
      overlayLeading,
      overlayTrailing,
      overlayContent.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 10),
      overlayContent.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -6),
      overlayContent.topAnchor.constraint(equalTo: overlay.topAnchor, constant: 4),
      overlayContent.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: -4),
      controls.heightAnchor.constraint(equalToConstant: 24),
      sizeEditor.heightAnchor.constraint(equalToConstant: 24),

      clickThroughBadge.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 8),
      clickThroughBadge.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -8),
      clickThroughBadge.heightAnchor.constraint(equalToConstant: 22),
      badgeImage.leadingAnchor.constraint(equalTo: clickThroughBadge.leadingAnchor, constant: 8),
      badgeImage.trailingAnchor.constraint(equalTo: clickThroughBadge.trailingAnchor, constant: -8),
      badgeImage.centerYAnchor.constraint(equalTo: clickThroughBadge.centerYAnchor),
    ])

    videoContainer.setContentHuggingPriority(.defaultLow, for: .vertical)
    videoContainer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
  }

  /// Dark HUD material for views floating over the video. The dark
  /// appearance is fixed because the backdrop is always video (or black),
  /// whatever the system appearance.
  private func configureHUD(_ view: NSVisualEffectView) {
    view.translatesAutoresizingMaskIntoConstraints = false
    view.material = .hudWindow
    view.blendingMode = .withinWindow
    view.state = .active
    view.appearance = NSAppearance(named: .darkAqua)
    view.wantsLayer = true
    view.layer?.cornerCurve = .continuous
    view.layer?.masksToBounds = true
  }

  private func configureIconButton(
    _ button: NSButton,
    symbol: String,
    label: String,
    identifier: String,
    action: Selector
  ) {
    button.translatesAutoresizingMaskIntoConstraints = false
    button.title = ""
    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
    button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
    button.imagePosition = .imageOnly
    button.imageScaling = .scaleProportionallyDown
    button.isBordered = false
    button.focusRingType = .none
    button.toolTip = label
    button.setAccessibilityIdentifier(identifier)
    button.setAccessibilityLabel(label)
    button.target = self
    button.action = action
    NSLayoutConstraint.activate([
      button.widthAnchor.constraint(equalToConstant: 24),
      button.heightAnchor.constraint(equalToConstant: 24),
    ])
  }

  private func configureSizeField(_ field: NSTextField, identifier: String, label: String) {
    let formatter = NumberFormatter()
    formatter.numberStyle = .none
    formatter.usesGroupingSeparator = false
    formatter.allowsFloats = false
    formatter.minimum = 1
    formatter.maximum = 9999

    field.translatesAutoresizingMaskIntoConstraints = false
    field.controlSize = .small
    field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    field.formatter = formatter
    field.isEditable = true
    field.isSelectable = true
    field.alignment = .right
    field.cell?.usesSingleLineMode = true
    field.cell?.isScrollable = true
    field.delegate = self
    field.setAccessibilityIdentifier(identifier)
    field.setAccessibilityLabel(label)

    let preferredWidth = field.widthAnchor.constraint(equalToConstant: 52)
    preferredWidth.priority = .defaultHigh
    NSLayoutConstraint.activate([
      field.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
      preferredWidth,
    ])
  }

  private func fillSizeFields() {
    let video = videoSize(forFrameSize: panel.frame.size)
    setSizeFieldValue(widthField, max(1, Int(video.width.rounded())))
    setSizeFieldValue(heightField, max(1, Int(video.height.rounded())))
  }

  private func syncHeightFromWidthField() {
    guard let aspect = displayAspect, let width = validatedSizeValue(of: widthField) else {
      return
    }
    setSizeFieldValue(heightField, linkedSizeValue(CGFloat(width) / aspect))
  }

  /// Rounds a derived dimension to a whole point, bounded so extreme
  /// aspects cannot overflow the integer conversion.
  private func linkedSizeValue(_ value: CGFloat) -> Int {
    Int(min(max(value.rounded(), 1), 99_999))
  }

  /// Writes `value` to `field` without triggering the aspect link. A field
  /// that is being edited is updated through its field editor.
  private func setSizeFieldValue(_ field: NSTextField, _ value: Int) {
    let text = String(value)
    isSyncingSizeFields = true
    defer { isSyncingSizeFields = false }
    if let editor = field.currentEditor() {
      editor.string = text
    } else {
      field.stringValue = text
    }
  }

  /// The field's current text (including uncommitted edits) as an integer.
  private func integerValue(of field: NSTextField) -> Int? {
    let text = (field.currentEditor()?.string ?? field.stringValue)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return Int(text)
  }

  private func validatedSizeValue(of field: NSTextField) -> Int? {
    guard let value = integerValue(of: field), (1...9999).contains(value) else { return nil }
    return value
  }

  private func applySizeEditing() {
    guard isEditingSize else { return }
    guard let width = validatedSizeValue(of: widthField) else {
      rejectSizeField(widthField)
      return
    }
    guard let height = validatedSizeValue(of: heightField) else {
      rejectSizeField(heightField)
      return
    }

    let videoWidth = CGFloat(width)
    let video: NSSize
    if let displayAspect {
      video = NSSize(width: videoWidth, height: videoWidth / displayAspect)
    } else {
      video = NSSize(width: videoWidth, height: CGFloat(height))
    }
    setFrameAnchoringTopLeft(size: fittedFrameSize(forVideoSize: video))
    endSizeEditing()
  }

  private func rejectSizeField(_ field: NSTextField) {
    NSSound.beep()
    if field.currentEditor() == nil {
      panel.makeFirstResponder(field)
    }
    field.currentEditor()?.selectAll(nil)
  }

  private func endSizeEditing() {
    guard isEditingSize else { return }
    isEditingSize = false
    // Discard uncommitted text so the formatter cannot refuse to end editing.
    widthField.abortEditing()
    heightField.abortEditing()
    panel.makeFirstResponder(nil)
    sizeEditor.isHidden = true
    controls.isHidden = false
    refreshOverlay(animated: true)
  }

  private func configureScreenChangeObservation() {
    let notificationCenter = NotificationCenter.default
    notificationCenter.addObserver(
      self,
      selector: #selector(screenParametersDidChange(_:)),
      name: NSApplication.didChangeScreenParametersNotification,
      object: nil
    )
    notificationCenter.addObserver(
      self,
      selector: #selector(windowOcclusionStateDidChange(_:)),
      name: NSWindow.didChangeOcclusionStateNotification,
      object: panel
    )
    NSWorkspace.shared.notificationCenter.addObserver(
      self,
      selector: #selector(activeSpaceDidChange(_:)),
      name: NSWorkspace.activeSpaceDidChangeNotification,
      object: nil
    )
  }

  private func requestVideoRedraw() {
    videoView.setNeedsDisplay(videoView.bounds)
  }

  @objc
  private func chooseWindowButtonPressed(_ sender: NSButton) {
    onChooseWindow?()
  }

  @objc
  private func cropButtonPressed(_ sender: NSButton) {
    onBeginCrop?()
  }

  @objc
  private func closeButtonPressed(_ sender: NSButton) {
    requestClose()
  }

  @objc
  private func applySizeButtonPressed(_ sender: NSButton) {
    applySizeEditing()
  }

  @objc
  private func cancelSizeButtonPressed(_ sender: NSButton) {
    endSizeEditing()
  }

  @objc
  private func screenParametersDidChange(_ notification: Notification) {
    repositionIfNeeded()
  }

  @objc
  private func windowOcclusionStateDidChange(_ notification: Notification) {
    guard panel.isVisible, panel.occlusionState.contains(.visible) else { return }
    requestVideoRedraw()
  }

  @objc
  private func activeSpaceDidChange(_ notification: Notification) {
    guard panel.isVisible else { return }
    requestVideoRedraw()
  }

  private func requestClose() {
    guard !closeCallbackDelivered else { return }
    closeCallbackDelivered = true
    endSizeEditing()
    cancelCropSelection()
    panel.orderOut(nil)
    onClose?()
  }

  private func repositionIfNeeded() {
    let currentFrame = panel.frame
    guard !currentFrame.isEmpty, let screen = Self.hostScreen(for: currentFrame) else { return }

    let constrained = Self.constrainedFrame(currentFrame, to: screen.visibleFrame)
    guard constrained != currentFrame else { return }
    panel.setFrame(constrained, display: panel.isVisible)
    emitVideoPixelSizeIfChanged()
  }

  private func emitVideoPixelSizeIfChanged() {
    let size = videoPixelSize
    guard size.width > 0, size.height > 0, size != lastEmittedVideoPixelSize else { return }
    lastEmittedVideoPixelSize = size
    onVideoPixelSizeChange?(size)
  }

  private func setFrameAnchoringTopLeft(size: NSSize) {
    let current = panel.frame
    var frame = NSRect(
      x: current.minX,
      y: current.maxY - size.height,
      width: size.width,
      height: size.height
    )
    if let screen = panel.screen ?? NSScreen.main {
      frame = Self.constrainedFrame(frame, to: screen.visibleFrame)
    }
    panel.setFrame(frame, display: panel.isVisible)
    emitVideoPixelSizeIfChanged()
  }

  /// Size of the non-video content, measured from the live layout so it
  /// tracks the content constraints. The video currently fills the content
  /// view (the hover overlay floats above it), so this is zero; the frame
  /// math still goes through it so any future chrome stays accounted for.
  private func contentChromeSize() -> NSSize {
    guard let contentView = panel.contentView else { return .zero }
    contentView.layoutSubtreeIfNeeded()
    return NSSize(
      width: max(0, contentView.bounds.width - videoContainer.frame.width),
      height: max(0, contentView.bounds.height - videoContainer.frame.height)
    )
  }

  private func frameSize(forVideoSize videoSize: NSSize) -> NSSize {
    let chrome = contentChromeSize()
    let contentSize = NSSize(
      width: videoSize.width + chrome.width,
      height: videoSize.height + chrome.height
    )
    return panel.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize)).size
  }

  private func videoSize(forFrameSize frameSize: NSSize) -> NSSize {
    let chrome = contentChromeSize()
    let contentSize = panel.contentRect(forFrameRect: NSRect(origin: .zero, size: frameSize)).size
    return NSSize(
      width: max(0, contentSize.width - chrome.width),
      height: max(0, contentSize.height - chrome.height)
    )
  }

  /// Frame size for `videoSize`, scaled uniformly (preserving the video
  /// aspect) to fit the screen's visible frame and then to satisfy
  /// `panel.minSize`. When both cannot hold, minSize wins and the renderer
  /// letterboxes.
  private func fittedFrameSize(forVideoSize videoSize: NSSize, on screen: NSScreen? = nil) -> NSSize {
    guard videoSize.width > 0, videoSize.height > 0,
      videoSize.width.isFinite, videoSize.height.isFinite
    else {
      return frameSize(forVideoSize: videoSize)
    }

    let unscaledFrame = frameSize(forVideoSize: videoSize)
    let chrome = NSSize(
      width: unscaledFrame.width - videoSize.width,
      height: unscaledFrame.height - videoSize.height
    )
    var scale: CGFloat = 1

    if let visible = (screen ?? panel.screen ?? NSScreen.main)?.visibleFrame.size,
      visible.width > 0, visible.height > 0,
      unscaledFrame.width > visible.width || unscaledFrame.height > visible.height
    {
      scale = min(
        (visible.width - chrome.width) / videoSize.width,
        (visible.height - chrome.height) / videoSize.height
      )
    }

    let minSize = panel.minSize
    let minScale = max(
      (minSize.width - chrome.width) / videoSize.width,
      (minSize.height - chrome.height) / videoSize.height
    )
    if scale < minScale {
      scale = minScale
    }

    return NSSize(
      width: videoSize.width * scale + chrome.width,
      height: videoSize.height * scale + chrome.height
    )
  }

  /// The screen whose visible frame contains the midpoint of `frame`. If that
  /// screen has disappeared, re-home on the primary visible display; the
  /// caller's constrainedFrame keeps the size unless it cannot fit there.
  private static func hostScreen(for frame: NSRect) -> NSScreen? {
    let midpoint = NSPoint(x: frame.midX, y: frame.midY)
    if let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(midpoint) }) {
      return screen
    }
    return NSScreen.main ?? NSScreen.screens.first
  }

  private static func initialFrame() -> NSRect {
    let size = NSSize(width: 480, height: 320)
    guard let screen = NSScreen.main ?? NSScreen.screens.first else {
      return NSRect(origin: .zero, size: size)
    }

    let visible = screen.visibleFrame
    let origin = NSPoint(
      x: visible.maxX - size.width - 24,
      y: visible.maxY - size.height - 24
    )
    return constrainedFrame(NSRect(origin: origin, size: size), to: visible)
  }

  /// Centered aspect fit of `aspect` (width / height) inside `bounds`, as the
  /// renderer letterboxes the video. A missing or invalid aspect yields
  /// `bounds`.
  private static func aspectFitRect(aspect: CGFloat?, in bounds: NSRect) -> NSRect {
    guard let aspect, aspect.isFinite, aspect > 0, bounds.width > 0, bounds.height > 0 else {
      return bounds
    }
    let size: NSSize
    if aspect > bounds.width / bounds.height {
      size = NSSize(width: bounds.width, height: bounds.width / aspect)
    } else {
      size = NSSize(width: bounds.height * aspect, height: bounds.height)
    }
    return NSRect(
      x: bounds.midX - size.width / 2,
      y: bounds.midY - size.height / 2,
      width: size.width,
      height: size.height
    )
  }

  private static func constrainedFrame(_ frame: NSRect, to visibleFrame: NSRect) -> NSRect {
    guard !visibleFrame.isEmpty else { return frame }

    var result = frame
    result.size.width = min(result.size.width, visibleFrame.width)
    result.size.height = min(result.size.height, visibleFrame.height)

    let maxX = visibleFrame.maxX - result.width
    let maxY = visibleFrame.maxY - result.height
    result.origin.x = min(max(result.origin.x, visibleFrame.minX), maxX)
    result.origin.y = min(max(result.origin.y, visibleFrame.minY), maxY)
    return result
  }

  private static func presentation(for state: CaptureState) -> (title: String, status: String) {
    switch state {
    case .idle:
      return ("PiP", L10n.string("state.idle"))
    case .selecting:
      return ("PiP", L10n.string("state.selecting"))
    case .starting:
      return ("PiP", L10n.string("state.starting"))
    case .running(let source):
      let name = displayText(source, fallback: L10n.string("capture.untitledWindow"))
      return ("PiP — \(name)", L10n.format("state.running", name))
    case .suspended(let reason):
      let paused = L10n.string("state.paused")
      let detail = displayText(reason, fallback: paused)
      return ("PiP", reason.isEmpty ? paused : L10n.format("state.pausedReason", detail))
    case .stopped(let reason):
      let stopped = L10n.string("state.stopped")
      let detail = displayText(reason, fallback: stopped)
      return ("PiP", reason.isEmpty ? stopped : L10n.format("state.stoppedReason", detail))
    case .failed(let reason):
      let error = L10n.string("state.error")
      let detail = displayText(reason, fallback: error)
      return ("PiP", reason.isEmpty ? error : L10n.format("state.failedReason", detail))
    }
  }

  private static func displayText(_ value: String, fallback: String) -> String {
    let compact =
      value
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !compact.isEmpty else { return fallback }
    return String(compact.prefix(160))
  }
}
