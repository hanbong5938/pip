import AppKit

/// Borderless/push button that reacts to the first click even when its panel is
/// not key (the PiP panel is nonactivating and the app is an accessory).
@MainActor
private final class FirstMouseButton: NSButton {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Document view for the row list; flipped so rows stack from the top.
@MainActor
private final class FlippedDocumentView: NSView {
  override var isFlipped: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// One capturable window: rounded card with app icon, app name, window title and
/// two trailing actions. Clicking anywhere outside the action buttons picks the
/// whole window.
@MainActor
private final class WindowRowView: NSView {
  private static let symbolConfiguration = NSImage.SymbolConfiguration(
    pointSize: 13, weight: .regular)

  private let windowID: CGWindowID
  private let onPick: (CGWindowID) -> Void
  private let onPickRegion: (CGWindowID) -> Void
  private let pickButton: FirstMouseButton
  private let regionButton: FirstMouseButton
  private var trackingArea: NSTrackingArea?
  private var isHovered = false {
    didSet { if isHovered != oldValue { needsDisplay = true } }
  }
  private var isPressed = false {
    didSet { if isPressed != oldValue { needsDisplay = true } }
  }

  init(
    window: CapturableWindow,
    onPick: @escaping (CGWindowID) -> Void,
    onPickRegion: @escaping (CGWindowID) -> Void
  ) {
    self.windowID = window.id
    self.onPick = onPick
    self.onPickRegion = onPickRegion
    self.pickButton = Self.makeActionButton(
      symbol: "pip.enter", label: L10n.string("windowList.pickWindow"))
    self.regionButton = Self.makeActionButton(
      symbol: "rectangle.dashed", label: L10n.string("windowList.pickRegion"))
    super.init(frame: .zero)
    configure(window: window)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() {
    // AppKit sets the drawing appearance for updateLayer, so dynamic colors
    // resolve correctly for light and dark mode here.
    let fill: NSColor
    if isPressed {
      fill = .secondarySystemFill
    } else if isHovered {
      fill = .tertiarySystemFill
    } else {
      fill = .quaternarySystemFill
    }
    layer?.backgroundColor = fill.cgColor
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  /// Labels and the icon would otherwise swallow clicks; only the action
  /// buttons keep their own hit testing.
  override func hitTest(_ point: NSPoint) -> NSView? {
    guard let hit = super.hitTest(point) else { return nil }
    if hit.isDescendant(of: pickButton) || hit.isDescendant(of: regionButton) {
      return hit
    }
    return self
  }

  override func updateTrackingAreas() {
    if let trackingArea {
      removeTrackingArea(trackingArea)
    }
    // `.activeAlways`: the panel is never key in normal use.
    let area = NSTrackingArea(
      rect: .zero,
      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
      owner: self,
      userInfo: nil)
    addTrackingArea(area)
    trackingArea = area
    super.updateTrackingAreas()
  }

  override func mouseEntered(with event: NSEvent) {
    isHovered = true
  }

  override func mouseExited(with event: NSEvent) {
    isHovered = false
    isPressed = false
  }

  override func mouseDown(with event: NSEvent) {
    isPressed = true
  }

  override func mouseDragged(with event: NSEvent) {
    isPressed = bounds.contains(convert(event.locationInWindow, from: nil))
  }

  override func mouseUp(with event: NSEvent) {
    let inside = bounds.contains(convert(event.locationInWindow, from: nil))
    isPressed = false
    if inside {
      onPick(windowID)
    }
  }

  override func accessibilityPerformPress() -> Bool {
    onPick(windowID)
    return true
  }

  @objc private func pickButtonPressed(_ sender: NSButton) {
    onPick(windowID)
  }

  @objc private func regionButtonPressed(_ sender: NSButton) {
    onPickRegion(windowID)
  }

  private func configure(window: CapturableWindow) {
    wantsLayer = true
    layer?.cornerRadius = 8
    layer?.cornerCurve = .continuous
    translatesAutoresizingMaskIntoConstraints = false

    let iconView = NSImageView()
    iconView.translatesAutoresizingMaskIntoConstraints = false
    iconView.imageScaling = .scaleProportionallyUpOrDown
    iconView.image =
      NSRunningApplication(processIdentifier: window.processID)?.icon
      ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)
    iconView.contentTintColor = .secondaryLabelColor
    iconView.setAccessibilityElement(false)

    let appLabel = NSTextField(labelWithString: window.appName)
    appLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
    appLabel.textColor = .labelColor
    configureSingleLine(appLabel)

    let textStack = NSStackView(views: [appLabel])
    textStack.orientation = .vertical
    textStack.alignment = .leading
    textStack.spacing = 1
    // Lowest hugging in the row: the text column absorbs spare width so the
    // action buttons sit at the trailing edge.
    textStack.setContentHuggingPriority(.init(1), for: .horizontal)
    textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    // Rows with an empty title show the app name only; otherwise the title
    // tells same-app windows apart.
    if !window.title.isEmpty {
      let titleLabel = NSTextField(labelWithString: window.title)
      titleLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
      titleLabel.textColor = .secondaryLabelColor
      configureSingleLine(titleLabel)
      textStack.addArrangedSubview(titleLabel)
    }

    pickButton.target = self
    pickButton.action = #selector(pickButtonPressed(_:))
    pickButton.setAccessibilityIdentifier("pip.windowList.row.\(window.id).window")
    regionButton.target = self
    regionButton.action = #selector(regionButtonPressed(_:))
    regionButton.setAccessibilityIdentifier("pip.windowList.row.\(window.id).region")

    let stack = NSStackView(views: [iconView, textStack, pickButton, regionButton])
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.distribution = .fill
    stack.spacing = 8
    stack.setCustomSpacing(4, after: pickButton)
    stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 6)
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)

    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
      heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
      iconView.widthAnchor.constraint(equalToConstant: 18),
      iconView.heightAnchor.constraint(equalToConstant: 18),
    ])

    toolTip = window.title.isEmpty ? window.appName : "\(window.appName) — \(window.title)"
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    setAccessibilityIdentifier("pip.windowList.row.\(window.id)")
    setAccessibilityLabel(
      window.title.isEmpty ? window.appName : "\(window.appName), \(window.title)")
    setAccessibilityHelp(L10n.string("windowList.pickWindow"))
  }

  private func configureSingleLine(_ label: NSTextField) {
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    label.cell?.truncatesLastVisibleLine = true
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    label.setContentHuggingPriority(.defaultLow, for: .horizontal)
    label.setAccessibilityElement(false)
  }

  private static func makeActionButton(symbol: String, label: String) -> FirstMouseButton {
    let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
      .withSymbolConfiguration(symbolConfiguration)
    let button = FirstMouseButton(frame: .zero)
    button.image = image
    button.imagePosition = .imageOnly
    button.isBordered = false
    button.contentTintColor = .controlAccentColor
    button.focusRingType = .none
    button.toolTip = label
    button.setAccessibilityLabel(label)
    button.setContentHuggingPriority(.required, for: .horizontal)
    button.setContentCompressionResistancePriority(.required, for: .horizontal)
    button.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      button.widthAnchor.constraint(equalToConstant: 24),
      button.heightAnchor.constraint(equalToConstant: 24),
    ])
    return button
  }
}

/// In-app source chooser shown over the PiP video area while no capture runs.
///
/// Fills its bounds with an opaque window background. The list is rebuilt only
/// when `setContent` receives different content, so periodic refreshes with an
/// unchanged window set do not flicker. All controls accept the first click
/// because the hosting panel is nonactivating and usually not key.
///
/// The bottom `bottomReservedHeight` points hold no controls: the panel floats
/// its status pill there. The list scrolls underneath via a bottom content
/// inset, and messages center above the strip.
@MainActor
final class WindowListView: NSView {
  enum Content: Equatable {
    case loading
    case permissionRequired
    case windows([CapturableWindow])
  }

  var onPick: ((CGWindowID) -> Void)?
  var onPickRegion: ((CGWindowID) -> Void)?
  var onRefresh: (() -> Void)?
  var onUseSystemPicker: (() -> Void)?
  var onRequestPermission: (() -> Void)?

  private static let messageMaxWidth: CGFloat = 280
  /// Bottom strip kept free for the panel's status HUD.
  private static let bottomReservedHeight: CGFloat = 40

  private var content: Content = .loading

  private let headerLabel = NSTextField(labelWithString: L10n.string("windowList.header"))
  private let refreshButton = FirstMouseButton(frame: .zero)
  private let bodyContainer = NSView()
  private let scrollView = NSScrollView()
  private let documentView = FlippedDocumentView()
  private let rowStack = NSStackView()
  private let messageStack = NSStackView()
  private let spinner = NSProgressIndicator()
  private let messageIcon = NSImageView()
  private let messageTitle = NSTextField(wrappingLabelWithString: "")
  private let messageBody = NSTextField(wrappingLabelWithString: "")
  private let permissionButton = FirstMouseButton(
    title: L10n.string("permission.open"), target: nil, action: nil)
  private let systemPickerButton = FirstMouseButton(
    title: L10n.string("windowList.systemPicker"), target: nil, action: nil)

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    configureView()
    render()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// Shows `content`; equal content is a no-op so the list does not flicker.
  func setContent(_ content: Content) {
    guard content != self.content else { return }
    self.content = content
    render()
  }

  override var isOpaque: Bool { true }
  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() {
    layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func layout() {
    // Wrapping labels need an explicit width to compute their height.
    let width = max(0, min(Self.messageMaxWidth, bounds.width - 32))
    if messageBody.preferredMaxLayoutWidth != width {
      messageBody.preferredMaxLayoutWidth = width
      messageTitle.preferredMaxLayoutWidth = width
    }
    super.layout()
  }

  // MARK: - Rendering

  private func render() {
    switch content {
    case .loading:
      showMessage(
        identifier: "pip.windowList.loading",
        spinning: true,
        symbol: nil,
        title: nil,
        body: L10n.string("windowList.loading"),
        showsPermissionButton: false)
    case .permissionRequired:
      showMessage(
        identifier: "pip.windowList.permission",
        spinning: false,
        symbol: "lock.shield",
        title: L10n.string("permission.title"),
        body: L10n.string("permission.body"),
        showsPermissionButton: true)
    case .windows(let windows) where windows.isEmpty:
      showMessage(
        identifier: "pip.windowList.empty",
        spinning: false,
        symbol: "macwindow",
        title: nil,
        body: L10n.string("windowList.empty"),
        showsPermissionButton: false)
    case .windows(let windows):
      showWindows(windows)
    }
  }

  private func showWindows(_ windows: [CapturableWindow]) {
    spinner.stopAnimation(nil)
    messageStack.isHidden = true
    scrollView.isHidden = false
    rebuildRows(windows)
  }

  private func showMessage(
    identifier: String,
    spinning: Bool,
    symbol: String?,
    title: String?,
    body: String,
    showsPermissionButton: Bool
  ) {
    rebuildRows([])
    scrollView.isHidden = true
    messageStack.isHidden = false

    spinner.isHidden = !spinning
    if spinning {
      spinner.startAnimation(nil)
    } else {
      spinner.stopAnimation(nil)
    }

    if let symbol {
      messageIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 24, weight: .regular))
      messageIcon.isHidden = false
    } else {
      messageIcon.image = nil
      messageIcon.isHidden = true
    }

    messageTitle.stringValue = title ?? ""
    messageTitle.isHidden = title == nil
    messageBody.stringValue = body
    permissionButton.isHidden = !showsPermissionButton

    messageStack.setAccessibilityIdentifier(identifier)
    messageStack.setAccessibilityLabel(title ?? body)
    needsLayout = true
  }

  private func rebuildRows(_ windows: [CapturableWindow]) {
    for row in rowStack.arrangedSubviews {
      rowStack.removeArrangedSubview(row)
      row.removeFromSuperview()
    }
    for window in windows {
      let row = WindowRowView(
        window: window,
        onPick: { [weak self] id in self?.onPick?(id) },
        onPickRegion: { [weak self] id in self?.onPickRegion?(id) })
      rowStack.addArrangedSubview(row)
      NSLayoutConstraint.activate([
        row.leadingAnchor.constraint(equalTo: rowStack.leadingAnchor),
        row.trailingAnchor.constraint(equalTo: rowStack.trailingAnchor),
      ])
    }
  }

  // MARK: - Actions

  @objc private func refreshPressed(_ sender: NSButton) {
    onRefresh?()
  }

  @objc private func systemPickerPressed(_ sender: NSButton) {
    onUseSystemPicker?()
  }

  @objc private func permissionPressed(_ sender: NSButton) {
    onRequestPermission?()
  }

  // MARK: - Setup

  private func configureView() {
    wantsLayer = true
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityIdentifier("pip.windowList")
    setAccessibilityLabel(L10n.string("windowList.accessibilityLabel"))

    let header = makeHeader()
    configureScrollView()
    configureMessageStack()

    bodyContainer.translatesAutoresizingMaskIntoConstraints = false
    bodyContainer.clipsToBounds = true
    bodyContainer.addSubview(scrollView)
    bodyContainer.addSubview(messageStack)

    addSubview(header)
    addSubview(bodyContainer)

    // Messages center in the body above the reserved bottom strip. None of the
    // vertical message constraints are required: in a panel too short for the
    // message it pins to the top and the overflow is clipped, rather than
    // forcing the panel taller.
    let messageArea = NSLayoutGuide()
    bodyContainer.addLayoutGuide(messageArea)
    let messageAreaBottom = messageArea.bottomAnchor.constraint(
      equalTo: bodyContainer.bottomAnchor, constant: -Self.bottomReservedHeight)
    messageAreaBottom.priority = .defaultHigh
    let messageTop = messageStack.topAnchor.constraint(
      greaterThanOrEqualTo: messageArea.topAnchor, constant: 4)
    messageTop.priority = .defaultHigh
    let messageCenter = messageStack.centerYAnchor.constraint(
      equalTo: messageArea.centerYAnchor)
    messageCenter.priority = .defaultLow

    NSLayoutConstraint.activate([
      header.topAnchor.constraint(equalTo: topAnchor, constant: 8),
      header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
      header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),

      bodyContainer.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
      bodyContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
      bodyContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
      bodyContainer.bottomAnchor.constraint(equalTo: bottomAnchor),

      scrollView.topAnchor.constraint(equalTo: bodyContainer.topAnchor),
      scrollView.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor),

      messageArea.topAnchor.constraint(equalTo: bodyContainer.topAnchor),
      messageAreaBottom,

      messageStack.centerXAnchor.constraint(equalTo: bodyContainer.centerXAnchor),
      messageTop,
      messageStack.leadingAnchor.constraint(
        greaterThanOrEqualTo: bodyContainer.leadingAnchor, constant: 16),
      messageStack.trailingAnchor.constraint(
        lessThanOrEqualTo: bodyContainer.trailingAnchor, constant: -16),
      messageStack.widthAnchor.constraint(lessThanOrEqualToConstant: Self.messageMaxWidth),
      messageCenter,
    ])
  }

  private func makeHeader() -> NSView {
    headerLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize - 1, weight: .semibold)
    headerLabel.textColor = .secondaryLabelColor
    headerLabel.lineBreakMode = .byTruncatingTail
    headerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    headerLabel.setAccessibilityRole(.staticText)
    headerLabel.setAccessibilityIdentifier("pip.windowList.header")

    let refreshLabel = L10n.string("windowList.refresh")
    refreshButton.image = NSImage(
      systemSymbolName: "arrow.clockwise", accessibilityDescription: refreshLabel)?
      .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
    refreshButton.imagePosition = .imageOnly
    refreshButton.isBordered = false
    refreshButton.contentTintColor = .secondaryLabelColor
    refreshButton.focusRingType = .none
    refreshButton.toolTip = refreshLabel
    refreshButton.setAccessibilityIdentifier("pip.windowList.refresh")
    refreshButton.setAccessibilityLabel(refreshLabel)
    refreshButton.target = self
    refreshButton.action = #selector(refreshPressed(_:))
    refreshButton.setContentHuggingPriority(.required, for: .horizontal)

    configureSystemPickerButton()

    let spacer = NSView()
    spacer.setContentHuggingPriority(.init(1), for: .horizontal)

    let header = NSStackView(views: [headerLabel, spacer, systemPickerButton, refreshButton])
    header.orientation = .horizontal
    header.alignment = .centerY
    header.spacing = 6
    header.setCustomSpacing(2, after: systemPickerButton)
    header.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      refreshButton.widthAnchor.constraint(equalToConstant: 22),
      refreshButton.heightAnchor.constraint(equalToConstant: 22),
    ])
    return header
  }

  private func configureSystemPickerButton() {
    let label = L10n.string("windowList.systemPicker")
    systemPickerButton.isBordered = false
    systemPickerButton.contentTintColor = .controlAccentColor
    systemPickerButton.controlSize = .small
    systemPickerButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    systemPickerButton.focusRingType = .none
    systemPickerButton.lineBreakMode = .byTruncatingTail
    systemPickerButton.toolTip = label
    systemPickerButton.setContentHuggingPriority(.required, for: .horizontal)
    systemPickerButton.setContentCompressionResistancePriority(
      .defaultLow + 1, for: .horizontal)
    systemPickerButton.setAccessibilityIdentifier("pip.windowList.systemPicker")
    systemPickerButton.setAccessibilityLabel(label)
    systemPickerButton.target = self
    systemPickerButton.action = #selector(systemPickerPressed(_:))
  }

  private func configureScrollView() {
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.scrollerStyle = .overlay
    scrollView.horizontalScrollElasticity = .none
    scrollView.automaticallyAdjustsContentInsets = false
    scrollView.contentInsets = NSEdgeInsets(
      top: 0, left: 0, bottom: Self.bottomReservedHeight, right: 0)
    scrollView.setAccessibilityIdentifier("pip.windowList.scroll")

    rowStack.orientation = .vertical
    rowStack.alignment = .leading
    rowStack.spacing = 4
    rowStack.translatesAutoresizingMaskIntoConstraints = false
    rowStack.setAccessibilityIdentifier("pip.windowList.rows")

    documentView.translatesAutoresizingMaskIntoConstraints = false
    documentView.addSubview(rowStack)
    scrollView.documentView = documentView

    let clipView = scrollView.contentView
    NSLayoutConstraint.activate([
      documentView.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
      documentView.topAnchor.constraint(equalTo: clipView.topAnchor),
      documentView.widthAnchor.constraint(equalTo: clipView.widthAnchor),

      rowStack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 2),
      rowStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 8),
      rowStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -8),
      rowStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -4),
    ])
  }

  private func configureMessageStack() {
    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.isDisplayedWhenStopped = false
    spinner.setAccessibilityElement(false)

    messageIcon.contentTintColor = .secondaryLabelColor
    messageIcon.imageScaling = .scaleNone
    messageIcon.setAccessibilityElement(false)

    messageTitle.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
    messageTitle.textColor = .labelColor
    messageTitle.alignment = .center
    messageTitle.isSelectable = false
    messageTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    messageBody.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    messageBody.textColor = .secondaryLabelColor
    messageBody.alignment = .center
    messageBody.isSelectable = false
    messageBody.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let permissionLabel = L10n.string("permission.open")
    permissionButton.bezelStyle = .push
    permissionButton.controlSize = .small
    permissionButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    permissionButton.bezelColor = .controlAccentColor
    permissionButton.focusRingType = .none
    permissionButton.setAccessibilityIdentifier("pip.windowList.permission.open")
    permissionButton.setAccessibilityLabel(permissionLabel)
    permissionButton.target = self
    permissionButton.action = #selector(permissionPressed(_:))

    for view in [spinner, messageIcon, messageTitle, messageBody, permissionButton] as [NSView] {
      messageStack.addArrangedSubview(view)
    }
    messageStack.orientation = .vertical
    messageStack.alignment = .centerX
    messageStack.spacing = 6
    messageStack.setCustomSpacing(10, after: messageBody)
    messageStack.translatesAutoresizingMaskIntoConstraints = false
    messageStack.setAccessibilityElement(true)
    messageStack.setAccessibilityRole(.group)
  }
}
