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
final class FloatingPanelController: NSObject {
  var onChooseWindow: (() -> Void)?
  var onClose: (() -> Void)?

  private let panel: PiPPanel
  private let videoView: NSView
  private let statusLabel: NSTextField
  private let chooseWindowButton: NSButton
  private let closeButton: NSButton
  private var closeCallbackDelivered = false

  init(videoView: NSView) {
    self.videoView = videoView

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

    let videoContainer = PassiveContainerView()
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

    let controls = NSStackView(views: [statusLabel, chooseWindowButton, closeButton])
    controls.translatesAutoresizingMaskIntoConstraints = false
    controls.orientation = .horizontal
    controls.alignment = .centerY
    controls.distribution = .fill
    controls.spacing = 8
    controls.setAccessibilityIdentifier("pip.controls")

    let stack = NSStackView(views: [videoContainer, controls])
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
      chooseWindowButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 72),
      closeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 56),
    ])

    videoContainer.setContentHuggingPriority(.defaultLow, for: .vertical)
    videoContainer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
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
    panel.orderOut(nil)
    onClose?()
  }

  private func repositionIfNeeded() {
    guard !NSScreen.screens.isEmpty else { return }

    let currentFrame = panel.frame
    guard !currentFrame.isEmpty else { return }

    if let screen = NSScreen.screens.first(where: { screen in
      screen.visibleFrame.contains(NSPoint(x: currentFrame.midX, y: currentFrame.midY))
    }) {
      let constrained = Self.constrainedFrame(currentFrame, to: screen.visibleFrame)
      guard constrained != currentFrame else { return }
      panel.setFrame(constrained, display: panel.isVisible)
      return
    }

    // The screen containing the panel may have disappeared. Re-home it
    // on the primary visible display without changing its size unless the
    // new visible frame cannot accommodate that size.
    let destination = NSScreen.main ?? NSScreen.screens[0]
    let constrained = Self.constrainedFrame(currentFrame, to: destination.visibleFrame)
    panel.setFrame(constrained, display: panel.isVisible)
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
