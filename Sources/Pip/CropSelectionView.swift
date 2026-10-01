import AppKit

/// Region picker overlaid on the PiP's displayed video.
///
/// The view is flipped, so the selection and the normalized result share a
/// top-left origin with the source window. The selection lives in view
/// coordinates and is always kept inside `contentRect` (the letterboxed video
/// rect) and at least `minimumSide` points on each side, unless the content
/// itself is smaller than that. A drag that ends smaller than the minimum is
/// discarded and the previous selection is restored.
@MainActor
final class CropSelectionView: NSView {
  enum Result: Equatable {
    /// Selection normalized to `contentRect`: top-left origin, every component in 0...1.
    case apply(CGRect)
    case reset
    case cancel
  }

  /// Sub-rect of `bounds` where the video is displayed. The selection keeps
  /// its relative position when this changes (e.g. the panel is resized) and
  /// is then re-clamped; it is only dropped if the rect becomes empty.
  var contentRect: NSRect = .zero {
    didSet {
      guard contentRect != oldValue else { return }
      if let selection {
        self.selection = remapped(selection, from: oldValue)
      } else {
        updateSelectionDependents()
      }
      needsLayout = true
    }
  }

  var onFinish: ((Result) -> Void)?

  private enum Handle: CaseIterable {
    // Corners first so they win hit tests over the adjacent edge midpoints.
    case topLeft, topRight, bottomRight, bottomLeft, top, right, bottom, left

    var movesMinX: Bool { self == .topLeft || self == .left || self == .bottomLeft }
    var movesMaxX: Bool { self == .topRight || self == .right || self == .bottomRight }
    var movesMinY: Bool { self == .topLeft || self == .top || self == .topRight }
    var movesMaxY: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
    var isCorner: Bool { (movesMinX || movesMaxX) && (movesMinY || movesMaxY) }

    /// Handle center on `rect`; the view is flipped, so "top" is `minY`.
    func point(on rect: NSRect) -> NSPoint {
      let x = movesMinX ? rect.minX : (movesMaxX ? rect.maxX : rect.midX)
      let y = movesMinY ? rect.minY : (movesMaxY ? rect.maxY : rect.midY)
      return NSPoint(x: x, y: y)
    }

    var cursor: NSCursor {
      let position: NSCursor.FrameResizePosition
      switch self {
      case .topLeft: position = .topLeft
      case .topRight: position = .topRight
      case .bottomRight: position = .bottomRight
      case .bottomLeft: position = .bottomLeft
      case .top: position = .top
      case .right: position = .right
      case .bottom: position = .bottom
      case .left: position = .left
      }
      return NSCursor.frameResize(position: position, directions: .all)
    }
  }

  private enum Drag {
    /// Mouse is down outside the selection but has not moved past the
    /// threshold yet, so the existing selection is still intact.
    case pendingCreate(anchor: NSPoint, previous: NSRect?)
    case create(anchor: NSPoint, previous: NSRect?)
    case move(start: NSPoint, original: NSRect)
    case resize(Handle, start: NSPoint, original: NSRect)
  }

  private static let minimumSide: CGFloat = 16
  private static let handleSize: CGFloat = 8
  private static let dragThreshold: CGFloat = 3
  private static let controlsBottomInset: CGFloat = 10
  private static let returnKeyCode: UInt16 = 36
  private static let keypadEnterKeyCode: UInt16 = 76
  private static let escapeKeyCode: UInt16 = 53

  /// Current selection in view coordinates; nil until the user drags one out.
  private var selection: NSRect? {
    didSet { updateSelectionDependents() }
  }
  private var drag: Drag?
  private var lastDragPoint: NSPoint?

  private let hintLabel = NSTextField(labelWithString: L10n.string("crop.hint"))
  private let controls = NSVisualEffectView()
  private var applyButton: NSButton!

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layerContentsRedrawPolicy = .onSetNeedsDisplay
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityIdentifier("pip.crop")
    setAccessibilityLabel(L10n.string("crop.accessibilityLabel"))

    configureHintLabel()
    configureControls()

    addTrackingArea(
      NSTrackingArea(
        rect: .zero,
        options: [.mouseMoved, .cursorUpdate, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
        owner: self,
        userInfo: nil
      ))
    updateSelectionDependents()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  /// Clears any selection and shows the hint. The caller makes the view first
  /// responder afterwards so Return and Escape reach it.
  func begin() {
    drag = nil
    lastDragPoint = nil
    selection = nil
  }

  // MARK: - Layout and drawing

  override func layout() {
    super.layout()
    let content = contentRect

    hintLabel.preferredMaxLayoutWidth = max(content.width - 24, 0)
    let hintSize = hintLabel.fittingSize
    hintLabel.frame = NSRect(
      x: content.midX - hintSize.width / 2,
      y: content.midY - hintSize.height / 2,
      width: hintSize.width,
      height: hintSize.height
    ).integral

    controls.isHidden = content.isEmpty
    let controlsSize = controls.fittingSize
    controls.frame = NSRect(
      x: content.midX - controlsSize.width / 2,
      y: max(content.minY, content.maxY - Self.controlsBottomInset - controlsSize.height),
      width: controlsSize.width,
      height: controlsSize.height
    ).integral
    controls.layer?.cornerRadius = controls.frame.height / 2
  }

  override func draw(_ dirtyRect: NSRect) {
    let content = contentRect
    guard content.width > 0, content.height > 0 else { return }

    // Dim the video outside the selection; the letterbox is left untouched.
    let dim = NSBezierPath(rect: content)
    if let selection {
      dim.append(NSBezierPath(rect: selection))
      dim.windingRule = .evenOdd
    }
    NSColor.black.withAlphaComponent(0.45).setFill()
    dim.fill()

    guard let selection else { return }

    let border = NSBezierPath(rect: selection.insetBy(dx: 0.75, dy: 0.75))
    border.lineWidth = 1.5
    NSColor.controlAccentColor.setStroke()
    border.stroke()

    let handlePaths = Handle.allCases.map {
      NSBezierPath(roundedRect: handleRect($0, on: selection), xRadius: 2, yRadius: 2)
    }
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 2
    shadow.shadowOffset = NSSize(width: 0, height: -0.5)
    shadow.set()
    NSColor.white.setFill()
    handlePaths.forEach { $0.fill() }
    NSGraphicsContext.restoreGraphicsState()
  }

  // MARK: - Mouse

  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    // The hint is decoration; clicks on it start a selection like anywhere else.
    return hit === hintLabel ? self : hit
  }

  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    guard !isOverControls(point), contentRect.width > 0, contentRect.height > 0 else { return }
    window?.makeFirstResponder(self)
    drag = nil

    if let selection {
      if event.clickCount == 2, selection.contains(point) {
        applyIfPossible()
        return
      }
      if let handle = handle(at: point, on: selection) {
        drag = .resize(handle, start: point, original: selection)
      } else if selection.contains(point) {
        drag = .move(start: point, original: selection)
      }
    }
    if drag == nil {
      drag = .pendingCreate(anchor: clampedToContent(point), previous: selection)
    }
    lastDragPoint = point
    updateCursor(at: point)
  }

  override func mouseDragged(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    lastDragPoint = point
    updateDrag(to: point, keepAspect: event.modifierFlags.contains(.shift))
    updateCursor(at: point)
  }

  override func mouseUp(with event: NSEvent) {
    if case .create(_, let previous) = drag, let selection,
      selection.width < minimumWidth || selection.height < minimumHeight
    {
      self.selection = previous
    }
    drag = nil
    lastDragPoint = nil
    updateCursor(at: convert(event.locationInWindow, from: nil))
  }

  override func flagsChanged(with event: NSEvent) {
    guard drag != nil, let lastDragPoint else {
      super.flagsChanged(with: event)
      return
    }
    updateDrag(to: lastDragPoint, keepAspect: event.modifierFlags.contains(.shift))
  }

  override func cursorUpdate(with event: NSEvent) {
    updateCursor(at: convert(event.locationInWindow, from: nil))
  }

  override func mouseMoved(with event: NSEvent) {
    guard drag == nil else { return }
    updateCursor(at: convert(event.locationInWindow, from: nil))
  }

  override func mouseExited(with event: NSEvent) {
    guard drag == nil else { return }
    NSCursor.arrow.set()
  }

  // MARK: - Keyboard

  override func keyDown(with event: NSEvent) {
    switch event.keyCode {
    case Self.returnKeyCode, Self.keypadEnterKeyCode:
      applyIfPossible()
    case Self.escapeKeyCode:
      finish(.cancel)
    default:
      super.keyDown(with: event)
    }
  }

  override func cancelOperation(_ sender: Any?) {
    finish(.cancel)
  }

  // MARK: - Actions

  @objc private func applyButtonPressed(_ sender: NSButton) {
    applyIfPossible()
  }

  @objc private func resetButtonPressed(_ sender: NSButton) {
    finish(.reset)
  }

  @objc private func cancelButtonPressed(_ sender: NSButton) {
    finish(.cancel)
  }

  private func applyIfPossible() {
    guard let normalized = normalizedSelection() else { return }
    finish(.apply(normalized))
  }

  private func finish(_ result: Result) {
    drag = nil
    lastDragPoint = nil
    onFinish?(result)
  }

  // MARK: - Selection geometry

  private var minimumWidth: CGFloat { min(Self.minimumSide, contentRect.width) }
  private var minimumHeight: CGFloat { min(Self.minimumSide, contentRect.height) }

  private func updateDrag(to point: NSPoint, keepAspect: Bool) {
    guard let drag else { return }
    switch drag {
    case .pendingCreate(let anchor, let previous):
      let start = clampedToContent(point)
      guard hypot(start.x - anchor.x, start.y - anchor.y) >= Self.dragThreshold else { return }
      self.drag = .create(anchor: anchor, previous: previous)
      updateDrag(to: point, keepAspect: keepAspect)
    case .create(let anchor, _):
      selection = createdRect(from: anchor, to: clampedToContent(point), keepAspect: keepAspect)
    case .move(let start, let original):
      let content = contentRect
      let x = min(max(original.minX + point.x - start.x, content.minX), content.maxX - original.width)
      let y = min(max(original.minY + point.y - start.y, content.minY), content.maxY - original.height)
      selection = NSRect(origin: NSPoint(x: x, y: y), size: original.size)
    case .resize(let handle, let start, let original):
      selection = resizedRect(
        original,
        handle: handle,
        dx: point.x - start.x,
        dy: point.y - start.y,
        keepAspect: keepAspect
      )
    }
  }

  /// Rect spanned by `anchor` and `point` (both already inside the content).
  /// With `keepAspect` the rect shrinks toward the anchor to the video's aspect,
  /// so it stays inside the content.
  private func createdRect(from anchor: NSPoint, to point: NSPoint, keepAspect: Bool) -> NSRect {
    var width = abs(point.x - anchor.x)
    var height = abs(point.y - anchor.y)
    if keepAspect, width > 0, height > 0 {
      let aspect = contentRect.width / contentRect.height
      if width / height > aspect {
        width = height * aspect
      } else {
        height = width / aspect
      }
    }
    return NSRect(
      x: point.x >= anchor.x ? anchor.x : anchor.x - width,
      y: point.y >= anchor.y ? anchor.y : anchor.y - height,
      width: width,
      height: height
    )
  }

  /// Moves the edges `handle` controls by the drag delta. Edges never cross:
  /// each moving edge stops `minimumSide` from its opposite edge and at the
  /// content bounds. With `keepAspect` corner drags keep the original aspect.
  private func resizedRect(
    _ original: NSRect, handle: Handle, dx: CGFloat, dy: CGFloat, keepAspect: Bool
  ) -> NSRect? {
    let content = contentRect
    var minX = original.minX
    var maxX = original.maxX
    var minY = original.minY
    var maxY = original.maxY
    if handle.movesMinX { minX = min(max(original.minX + dx, content.minX), maxX - minimumWidth) }
    if handle.movesMaxX { maxX = max(min(original.maxX + dx, content.maxX), minX + minimumWidth) }
    if handle.movesMinY { minY = min(max(original.minY + dy, content.minY), maxY - minimumHeight) }
    if handle.movesMaxY { maxY = max(min(original.maxY + dy, content.maxY), minY + minimumHeight) }

    if keepAspect, handle.isCorner, original.width > 0, original.height > 0 {
      let aspect = original.width / original.height
      var width = maxX - minX
      var height = maxY - minY
      // Shrinking toward the fixed corner keeps the rect inside the content.
      if width / height > aspect {
        width = height * aspect
      } else {
        height = width / aspect
      }
      if width < minimumWidth || height < minimumHeight {
        let scale = max(minimumWidth / width, minimumHeight / height)
        width *= scale
        height *= scale
      }
      if handle.movesMinX { minX = maxX - width } else { maxX = minX + width }
      if handle.movesMinY { minY = maxY - height } else { maxY = minY + height }
    }
    return clampedToContent(NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
  }

  /// Maps `rect` from its position in `oldContent` to the same relative
  /// position in the current content, then clamps it.
  private func remapped(_ rect: NSRect, from oldContent: NSRect) -> NSRect? {
    guard oldContent.width > 0, oldContent.height > 0 else { return clampedToContent(rect) }
    let content = contentRect
    let scaleX = content.width / oldContent.width
    let scaleY = content.height / oldContent.height
    return clampedToContent(
      NSRect(
        x: content.minX + (rect.minX - oldContent.minX) * scaleX,
        y: content.minY + (rect.minY - oldContent.minY) * scaleY,
        width: rect.width * scaleX,
        height: rect.height * scaleY
      ))
  }

  /// Fits `rect` inside the content at no less than the minimum size, or nil
  /// when there is no content to select from.
  private func clampedToContent(_ rect: NSRect) -> NSRect? {
    let content = contentRect
    guard content.width > 0, content.height > 0 else { return nil }
    let width = min(max(rect.width, minimumWidth), content.width)
    let height = min(max(rect.height, minimumHeight), content.height)
    return NSRect(
      x: min(max(rect.minX, content.minX), content.maxX - width),
      y: min(max(rect.minY, content.minY), content.maxY - height),
      width: width,
      height: height
    )
  }

  private func clampedToContent(_ point: NSPoint) -> NSPoint {
    NSPoint(
      x: min(max(point.x, contentRect.minX), contentRect.maxX),
      y: min(max(point.y, contentRect.minY), contentRect.maxY)
    )
  }

  private func normalizedSelection() -> CGRect? {
    let content = contentRect
    guard let selection, content.width > 0, content.height > 0 else { return nil }
    let x = min(max((selection.minX - content.minX) / content.width, 0), 1)
    let y = min(max((selection.minY - content.minY) / content.height, 0), 1)
    let width = min(max(selection.width / content.width, 0), 1 - x)
    let height = min(max(selection.height / content.height, 0), 1 - y)
    guard width > 0, height > 0 else { return nil }
    return CGRect(x: x, y: y, width: width, height: height)
  }

  private func handleRect(_ handle: Handle, on selection: NSRect) -> NSRect {
    let center = handle.point(on: selection)
    let half = Self.handleSize / 2
    return NSRect(
      x: center.x - half, y: center.y - half, width: Self.handleSize, height: Self.handleSize)
  }

  private func handle(at point: NSPoint, on selection: NSRect) -> Handle? {
    Handle.allCases.first { handleRect($0, on: selection).contains(point) }
  }

  // MARK: - State presentation

  private func updateSelectionDependents() {
    let hasSelection = selection != nil
    hintLabel.isHidden = hasSelection || contentRect.isEmpty
    applyButton.isEnabled = hasSelection
    applyButton.contentTintColor = hasSelection ? .controlAccentColor : nil
    needsDisplay = true
  }

  private func isOverControls(_ point: NSPoint) -> Bool {
    !controls.isHidden && controls.frame.contains(point)
  }

  private func updateCursor(at point: NSPoint) {
    cursor(at: point).set()
  }

  private func cursor(at point: NSPoint) -> NSCursor {
    switch drag {
    case .move: return .closedHand
    case .resize(let handle, _, _): return handle.cursor
    case .create, .pendingCreate: return .crosshair
    case nil: break
    }
    if isOverControls(point) { return .arrow }
    if let selection {
      if let handle = handle(at: point, on: selection) { return handle.cursor }
      if selection.contains(point) { return .openHand }
    }
    return contentRect.contains(point) ? .crosshair : .arrow
  }

  // MARK: - Subviews

  private func configureHintLabel() {
    hintLabel.font = .systemFont(ofSize: 13, weight: .medium)
    hintLabel.textColor = .white
    hintLabel.alignment = .center
    hintLabel.lineBreakMode = .byWordWrapping
    hintLabel.maximumNumberOfLines = 0
    hintLabel.isSelectable = false
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
    shadow.shadowBlurRadius = 3
    shadow.shadowOffset = NSSize(width: 0, height: -1)
    hintLabel.shadow = shadow
    hintLabel.setAccessibilityIdentifier("pip.crop.hint")
    addSubview(hintLabel)
  }

  private func configureControls() {
    let apply = makeButton(
      symbol: "checkmark",
      label: L10n.string("crop.apply"),
      identifier: "pip.crop.apply",
      action: #selector(applyButtonPressed(_:))
    )
    let reset = makeButton(
      symbol: "arrow.up.left.and.arrow.down.right",
      label: L10n.string("crop.reset"),
      identifier: "pip.crop.reset",
      action: #selector(resetButtonPressed(_:))
    )
    let cancel = makeButton(
      symbol: "xmark",
      label: L10n.string("crop.cancel"),
      identifier: "pip.crop.cancel",
      action: #selector(cancelButtonPressed(_:))
    )
    applyButton = apply

    let stack = NSStackView(views: [apply, reset, cancel])
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = 2

    // The pill floats over (dimmed) video, so it is always a dark HUD.
    controls.material = .hudWindow
    controls.blendingMode = .withinWindow
    controls.state = .active
    controls.appearance = NSAppearance(named: .darkAqua)
    controls.wantsLayer = true
    controls.layer?.masksToBounds = true
    controls.setAccessibilityIdentifier("pip.crop.controls")
    controls.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: controls.leadingAnchor, constant: 6),
      stack.trailingAnchor.constraint(equalTo: controls.trailingAnchor, constant: -6),
      stack.topAnchor.constraint(equalTo: controls.topAnchor, constant: 3),
      stack.bottomAnchor.constraint(equalTo: controls.bottomAnchor, constant: -3),
    ])
    addSubview(controls)
  }

  private func makeButton(
    symbol: String, label: String, identifier: String, action: Selector
  ) -> NSButton {
    let image =
      NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage()
    let button = FirstMouseButton(image: image, target: self, action: action)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.isBordered = false
    button.imagePosition = .imageOnly
    button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
    button.refusesFirstResponder = true
    button.focusRingType = .none
    button.toolTip = label
    button.setAccessibilityIdentifier(identifier)
    button.setAccessibilityLabel(label)
    NSLayoutConstraint.activate([
      button.widthAnchor.constraint(equalToConstant: 28),
      button.heightAnchor.constraint(equalToConstant: 24),
    ])
    return button
  }
}

/// Lets a pill button act on the first click even while the panel is not key.
@MainActor
private final class FirstMouseButton: NSButton {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
