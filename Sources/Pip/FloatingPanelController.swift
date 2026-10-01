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

@MainActor
private final class PassiveContainerView: NSView {
  override var acceptsFirstResponder: Bool { false }
}

@MainActor
final class FloatingPanelController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
  var onChooseWindow: (() -> Void)?
  var onClose: (() -> Void)?
  var onVideoPixelSizeChange: ((CGSize) -> Void)?

  private let panel: PiPPanel
  private let videoView: NSView
  private let videoContainer: PassiveContainerView
  private let statusLabel: NSTextField
  private let chooseWindowButton: NSButton
  private let closeButton: NSButton
  private let controls: NSStackView
  private let sizeEditor: NSStackView
  private let widthField: NSTextField
  private let heightField: NSTextField
  private let applySizeButton: NSButton
  private let cancelSizeButton: NSButton
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

  init(videoView: NSView) {
    self.videoView = videoView
    self.videoContainer = PassiveContainerView()

    let initialFrame = Self.initialFrame()
    self.panel = PiPPanel(
      contentRect: initialFrame,
      styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
      backing: .buffered,
      defer: true
    )
    self.statusLabel = NSTextField(labelWithString: "창을 선택하세요")
    self.chooseWindowButton = NSButton(title: "창 선택", target: nil, action: nil)
    self.closeButton = NSButton(title: "닫기", target: nil, action: nil)
    self.controls = NSStackView()
    self.sizeEditor = NSStackView()
    self.widthField = NSTextField(string: "")
    self.heightField = NSTextField(string: "")
    self.applySizeButton = NSButton(title: "적용", target: nil, action: nil)
    self.cancelSizeButton = NSButton(title: "취소", target: nil, action: nil)

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

  /// Exchanges the width and height of the video area for a 90°/270° display
  /// rotation, keeping the panel's chrome, center, and on-screen placement.
  /// The requested size is remembered before the minSize clamp so that
  /// rotating back restores the original panel size exactly.
  /// Works while the panel is hidden; only the frame is updated then.
  func swapVideoOrientation() {
    isOrientationSwapped.toggle()
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
  }

  /// Shows the panel and replaces the bottom controls row with an inline
  /// width × height editor for the video area, in points. Only the panel
  /// becomes key; the application is never activated.
  func beginCustomSizeEditing() {
    show()
    isEditingSize = true
    controls.isHidden = true
    sizeEditor.isHidden = false
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
    panel.minSize = NSSize(width: 320, height: 220)
    // Restores a saved frame (if any) immediately; initialFrame() covers
    // the first launch. show() re-homes frames from disconnected screens.
    _ = panel.setFrameAutosaveName("pip.panel")
    panel.delegate = self
    panel.setAccessibilityIdentifier("pip.panel")
    panel.setAccessibilityLabel("화면 속 화면")

    panel.onCloseRequested = { [weak self] in
      self?.requestClose()
    }

    // Keep the standard title-bar close affordance, but route it through
    // the same once-only callback as the explicit content button.
    if let standardClose = panel.standardWindowButton(.closeButton) {
      standardClose.target = self
      standardClose.action = #selector(closeButtonPressed(_:))
      standardClose.setAccessibilityIdentifier("pip.titlebar.close")
      standardClose.setAccessibilityLabel("닫기")
    }
  }

  private func configureContent() {
    let rootView = PassiveContainerView()
    panel.contentView = rootView
    rootView.setAccessibilityIdentifier("pip.content")

    videoContainer.wantsLayer = true
    videoContainer.layer?.backgroundColor = NSColor.black.cgColor
    videoContainer.setAccessibilityIdentifier("pip.video.container")
    videoContainer.setAccessibilityLabel("실시간 화면")

    videoView.translatesAutoresizingMaskIntoConstraints = false
    videoView.setAccessibilityIdentifier("pip.video")
    videoView.setAccessibilityLabel("실시간 화면")
    videoContainer.addSubview(videoView)

    NSLayoutConstraint.activate([
      videoView.leadingAnchor.constraint(equalTo: videoContainer.leadingAnchor),
      videoView.trailingAnchor.constraint(equalTo: videoContainer.trailingAnchor),
      videoView.topAnchor.constraint(equalTo: videoContainer.topAnchor),
      videoView.bottomAnchor.constraint(equalTo: videoContainer.bottomAnchor),
    ])

    statusLabel.translatesAutoresizingMaskIntoConstraints = false
    statusLabel.alignment = .left
    statusLabel.lineBreakMode = .byTruncatingTail
    statusLabel.maximumNumberOfLines = 1
    statusLabel.isSelectable = false
    statusLabel.isEditable = false
    statusLabel.setAccessibilityIdentifier("pip.status")
    statusLabel.setAccessibilityLabel("상태")
    statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
    statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    chooseWindowButton.translatesAutoresizingMaskIntoConstraints = false
    chooseWindowButton.bezelStyle = .rounded
    chooseWindowButton.setAccessibilityIdentifier("pip.chooseWindow")
    chooseWindowButton.setAccessibilityLabel("창 선택")
    chooseWindowButton.focusRingType = .none
    chooseWindowButton.target = self
    chooseWindowButton.action = #selector(chooseWindowButtonPressed(_:))

    closeButton.translatesAutoresizingMaskIntoConstraints = false
    closeButton.bezelStyle = .rounded
    closeButton.setAccessibilityIdentifier("pip.close")
    closeButton.setAccessibilityLabel("닫기")
    closeButton.focusRingType = .none
    closeButton.target = self
    closeButton.action = #selector(closeButtonPressed(_:))

    for view in [statusLabel, chooseWindowButton, closeButton] {
      controls.addArrangedSubview(view)
    }
    controls.translatesAutoresizingMaskIntoConstraints = false
    controls.orientation = .horizontal
    controls.alignment = .centerY
    controls.distribution = .fill
    controls.spacing = 8
    controls.setAccessibilityIdentifier("pip.controls")

    configureSizeField(widthField, identifier: "pip.size.width", label: "너비")
    configureSizeField(heightField, identifier: "pip.size.height", label: "높이")

    let timesLabel = NSTextField(labelWithString: "×")
    timesLabel.translatesAutoresizingMaskIntoConstraints = false
    timesLabel.setAccessibilityElement(false)

    applySizeButton.translatesAutoresizingMaskIntoConstraints = false
    applySizeButton.bezelStyle = .rounded
    applySizeButton.keyEquivalent = "\r"
    applySizeButton.setAccessibilityIdentifier("pip.size.apply")
    applySizeButton.setAccessibilityLabel("적용")
    applySizeButton.focusRingType = .none
    applySizeButton.target = self
    applySizeButton.action = #selector(applySizeButtonPressed(_:))

    cancelSizeButton.translatesAutoresizingMaskIntoConstraints = false
    cancelSizeButton.bezelStyle = .rounded
    cancelSizeButton.keyEquivalent = "\u{1b}"
    cancelSizeButton.setAccessibilityIdentifier("pip.size.cancel")
    cancelSizeButton.setAccessibilityLabel("취소")
    cancelSizeButton.focusRingType = .none
    cancelSizeButton.target = self
    cancelSizeButton.action = #selector(cancelSizeButtonPressed(_:))

    // Absorbs spare width so the buttons sit at the trailing edge, like the
    // regular controls row.
    let sizeEditorSpacer = NSView()
    sizeEditorSpacer.translatesAutoresizingMaskIntoConstraints = false
    sizeEditorSpacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
    sizeEditorSpacer.setContentCompressionResistancePriority(
      NSLayoutConstraint.Priority(1),
      for: .horizontal
    )

    for view in [
      widthField, timesLabel, heightField, sizeEditorSpacer, applySizeButton, cancelSizeButton,
    ] {
      sizeEditor.addArrangedSubview(view)
    }
    sizeEditor.translatesAutoresizingMaskIntoConstraints = false
    sizeEditor.orientation = .horizontal
    sizeEditor.alignment = .centerY
    sizeEditor.distribution = .fill
    sizeEditor.spacing = 8
    sizeEditor.setAccessibilityIdentifier("pip.size.editor")
    sizeEditor.isHidden = true

    // Hidden rows are detached (NSStackView default), so exactly one 30pt
    // bottom row is laid out in either mode and the chrome size is stable.
    let stack = NSStackView(views: [videoContainer, controls, sizeEditor])
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.orientation = .vertical
    stack.alignment = .width
    stack.distribution = .fill
    stack.spacing = 8
    stack.setAccessibilityIdentifier("pip.layout")

    rootView.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 12),
      stack.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -12),
      stack.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 12),
      stack.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -12),
      videoContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
      controls.heightAnchor.constraint(equalToConstant: 30),
      sizeEditor.heightAnchor.constraint(equalToConstant: 30),
      chooseWindowButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 72),
      closeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 56),
      applySizeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 56),
      cancelSizeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 56),
    ])

    videoContainer.setContentHuggingPriority(.defaultLow, for: .vertical)
    videoContainer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
  }

  private func configureSizeField(_ field: NSTextField, identifier: String, label: String) {
    let formatter = NumberFormatter()
    formatter.numberStyle = .none
    formatter.usesGroupingSeparator = false
    formatter.allowsFloats = false
    formatter.minimum = 1
    formatter.maximum = 9999

    field.translatesAutoresizingMaskIntoConstraints = false
    field.formatter = formatter
    field.isEditable = true
    field.isSelectable = true
    field.alignment = .right
    field.cell?.usesSingleLineMode = true
    field.cell?.isScrollable = true
    field.delegate = self
    field.setAccessibilityIdentifier(identifier)
    field.setAccessibilityLabel(label)

    let preferredWidth = field.widthAnchor.constraint(equalToConstant: 60)
    preferredWidth.priority = .defaultHigh
    NSLayoutConstraint.activate([
      field.widthAnchor.constraint(greaterThanOrEqualToConstant: 56),
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

  /// Size of the non-video content (padding and controls), measured from
  /// the live layout so it tracks the content constraints.
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
      return ("PiP", "창을 선택하세요")
    case .selecting:
      return ("PiP", "창 선택 중…")
    case .starting:
      return ("PiP", "시작 중…")
    case .running(let source):
      let name = displayText(source, fallback: "창")
      return ("PiP — \(name)", "실시간: \(name)")
    case .suspended(let reason):
      let detail = displayText(reason, fallback: "일시 중지됨")
      return ("PiP", reason.isEmpty ? "일시 중지됨" : "일시 중지됨: \(detail)")
    case .stopped(let reason):
      let detail = displayText(reason, fallback: "중지됨")
      return ("PiP", reason.isEmpty ? "중지됨" : "중지됨: \(detail)")
    case .failed(let reason):
      let detail = displayText(reason, fallback: "오류")
      return ("PiP", reason.isEmpty ? "오류" : "실패: \(detail)")
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
