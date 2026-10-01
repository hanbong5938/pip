import AppKit
import Foundation

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private static let sizePresets: [(key: String, identifier: String, videoWidth: CGFloat)] = [
    ("menu.sizeSmall", "size-small", 360),
    ("menu.sizeMedium", "size-medium", 480),
    ("menu.sizeLarge", "size-large", 720),
  ]
  private static let opacityPresets: [Double] = [1.0, 0.75, 0.5, 0.25]

  private let settings = AppSettings()
  private lazy var manager = PiPManager(settings: settings)
  private var statusItem: NSStatusItem?
  private var statusMenu: NSMenu?
  /// The "Choose Window" submenu being filled; only one is open at a time.
  private weak var activeWindowMenu: WindowMenu?
  private var windowMenuTask: Task<Void, Never>?
  private var settingsWindowController: SettingsWindowController?
  /// Registered while `settings.clickThroughHotKeyEnabled`.
  private var clickThroughHotKey: GlobalHotKey?
  private var terminationTask: Task<Void, Never>?
  private var isTerminating = false
  private var terminationReplySent = false
  private var didFinishLaunching = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    guard !didFinishLaunching else { return }
    didFinishLaunching = true

    NSApp.setActivationPolicy(.accessory)
    settings.onChange = { [weak self] in
      self?.settingsDidChange()
    }
    updateClickThroughHotKey()
    createStatusItem()
    manager.newSession()
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if terminationReplySent {
      return .terminateNow
    }
    guard !isTerminating else {
      return .terminateCancel
    }

    isTerminating = true
    windowMenuTask?.cancel()
    windowMenuTask = nil
    clickThroughHotKey?.unregister()
    clickThroughHotKey = nil
    // Suppress panel-originated actions now; the shutdown task runs later.
    manager.beginShutdown()
    terminationTask = Task { @MainActor [self] in
      await manager.shutdownAll()

      guard !terminationReplySent else { return }
      terminationReplySent = true
      NSApp.reply(toApplicationShouldTerminate: true)
      terminationTask = nil
    }
    return .terminateLater
  }

  // Relaunching from Finder/Spotlight/Raycast while the menu-bar app is running
  // only sends a reopen event, so bring back the panels the user closed.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    if !isTerminating {
      manager.showAll()
    }
    return false
  }

  // MARK: - Settings and click-through

  private func settingsDidChange() {
    updateClickThroughHotKey()
  }

  private func updateClickThroughHotKey() {
    guard !isTerminating, settings.clickThroughHotKeyEnabled else {
      clickThroughHotKey?.unregister()
      clickThroughHotKey = nil
      return
    }
    guard clickThroughHotKey == nil else { return }
    clickThroughHotKey = GlobalHotKey(
      keyCode: GlobalHotKey.clickThroughKeyCode,
      modifiers: GlobalHotKey.clickThroughModifiers
    ) { [weak self] in
      self?.toggleClickThrough()
    }
  }

  private func toggleClickThrough() {
    setClickThrough(!manager.isClickThrough)
  }

  /// App-wide: every PiP panel lets clicks pass through while this is on.
  private func setClickThrough(_ enabled: Bool) {
    guard !isTerminating else { return }
    manager.setClickThrough(enabled)
  }

  // MARK: - Status menu

  private func createStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    if let button = item.button {
      let label = L10n.string("menu.accessibilityLabel")
      let image = NSImage(systemSymbolName: "pip", accessibilityDescription: label)
      image?.isTemplate = true
      button.image = image
      button.setAccessibilityLabel(label)
      button.setAccessibilityIdentifier("pip.status-item")
    }

    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.delegate = self
    item.menu = menu
    statusMenu = menu
    statusItem = item
    rebuildStatusMenu(menu)
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    if menu === statusMenu {
      rebuildStatusMenu(menu)
    } else if let windowMenu = menu as? WindowMenu {
      populateWindowMenu(windowMenu)
    }
  }

  /// Rebuilt every time the menu opens so titles, checkmarks, and enabled
  /// states reflect the PiPs right now. One PiP keeps its items flat; with
  /// several, each PiP gets a numbered submenu and the app-wide items follow.
  private func rebuildStatusMenu(_ menu: NSMenu) {
    windowMenuTask?.cancel()
    windowMenuTask = nil
    activeWindowMenu = nil
    menu.removeAllItems()

    let sessions = manager.sessions
    let hasSessions = !isTerminating && !sessions.isEmpty

    let newItem = makeMenuItem(
      title: L10n.string("menu.newPiP"),
      action: #selector(newPiPFromMenu(_:)),
      identifier: "pip.menu.new-pip",
      isEnabled: !isTerminating
    )
    newItem.keyEquivalent = "n"
    newItem.keyEquivalentModifierMask = [.command]
    menu.addItem(newItem)
    menu.addItem(.separator())

    let singleSession = sessions.count == 1 ? sessions.first : nil
    if let singleSession {
      addSessionItems(for: singleSession, to: menu, identifierPrefix: "pip.menu.")
    } else if !sessions.isEmpty {
      for (index, session) in sessions.enumerated() {
        let number = index + 1
        let prefix = "pip.menu.pip-\(number)."
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        addSessionItems(for: session, to: submenu, identifierPrefix: prefix)
        submenu.addItem(.separator())
        submenu.addItem(makeStopItem(for: session, identifierPrefix: prefix))
        submenu.addItem(
          makeMenuItem(
            title: L10n.string("menu.closePiP"),
            action: #selector(closePiPFromMenu(_:)),
            identifier: prefix + "close",
            isEnabled: !isTerminating,
            session: session
          ))
        menu.addItem(
          makeSubmenuItem(
            title: L10n.format("menu.pipItem", number, session.displayTitle),
            identifier: "pip.menu.pip-\(number)",
            submenu: submenu,
            isEnabled: !isTerminating
          ))
      }
      menu.addItem(.separator())
    }

    let clickThroughItem = makeMenuItem(
      title: L10n.string("menu.clickThrough"),
      action: #selector(toggleClickThroughFromMenu(_:)),
      identifier: "pip.menu.click-through",
      isEnabled: hasSessions
    )
    clickThroughItem.state = manager.isClickThrough ? .on : .off
    // Shown for discoverability; the global hot key does the actual work and
    // also fires while the app is in the background.
    clickThroughItem.keyEquivalent = "p"
    clickThroughItem.keyEquivalentModifierMask = [.control, .option]
    menu.addItem(clickThroughItem)
    menu.addItem(
      makeMenuItem(
        title: L10n.string("menu.closeAll"),
        action: #selector(closeAllFromMenu(_:)),
        identifier: "pip.menu.close-all",
        isEnabled: hasSessions
      ))

    menu.addItem(.separator())
    let settingsItem = makeMenuItem(
      title: L10n.string("menu.settings"),
      action: #selector(showSettingsFromMenu(_:)),
      identifier: "pip.menu.settings",
      isEnabled: !isTerminating
    )
    settingsItem.keyEquivalent = ","
    settingsItem.keyEquivalentModifierMask = [.command]
    menu.addItem(settingsItem)

    if let singleSession {
      menu.addItem(makeStopItem(for: singleSession, identifierPrefix: "pip.menu."))
    }
    menu.addItem(
      makeMenuItem(
        title: L10n.string("menu.quit"),
        action: #selector(quitFromMenu(_:)),
        identifier: "pip.menu.quit",
        isEnabled: !isTerminating
      ))
  }

  /// Per-PiP items from "Choose Window" through "Size". Every item targets
  /// `session` through its `PiPMenuTarget`.
  private func addSessionItems(
    for session: PiPSession, to menu: NSMenu, identifierPrefix prefix: String
  ) {
    let isActive = !isTerminating

    let windowMenu = WindowMenu()
    windowMenu.autoenablesItems = false
    windowMenu.delegate = self
    windowMenu.session = session
    windowMenu.identifierPrefix = prefix
    menu.addItem(
      makeSubmenuItem(
        title: L10n.string("menu.chooseWindow"),
        identifier: prefix + "choose-window",
        submenu: windowMenu,
        isEnabled: isActive
      ))

    menu.addItem(
      makeMenuItem(
        title: L10n.string("menu.showPanel"),
        action: #selector(showPanelFromMenu(_:)),
        identifier: prefix + "show-panel",
        isEnabled: isActive,
        session: session
      ))

    menu.addItem(.separator())
    menu.addItem(
      makeMenuItem(
        title: L10n.string("menu.selectRegion"),
        action: #selector(selectRegionFromMenu(_:)),
        identifier: prefix + "select-region",
        isEnabled: isActive && session.canSelectRegion,
        session: session
      ))
    menu.addItem(
      makeMenuItem(
        title: L10n.string("menu.resetRegion"),
        action: #selector(resetRegionFromMenu(_:)),
        identifier: prefix + "reset-region",
        isEnabled: isActive && session.crop != nil,
        session: session
      ))

    menu.addItem(.separator())
    menu.addItem(
      makeSubmenuItem(
        title: L10n.string("menu.frameRate"),
        identifier: prefix + "frame-rate",
        submenu: makeFrameRateMenu(for: session, identifierPrefix: prefix, isEnabled: isActive),
        isEnabled: isActive
      ))
    menu.addItem(
      makeSubmenuItem(
        title: L10n.string("menu.opacity"),
        identifier: prefix + "opacity",
        submenu: makeOpacityMenu(for: session, identifierPrefix: prefix, isEnabled: isActive),
        isEnabled: isActive
      ))
    menu.addItem(
      makeMenuItem(
        title: L10n.format("menu.rotate", session.rotation.degrees),
        action: #selector(rotateFromMenu(_:)),
        identifier: prefix + "rotate",
        isEnabled: isActive,
        session: session
      ))
    menu.addItem(
      makeSubmenuItem(
        title: L10n.string("menu.size"),
        identifier: prefix + "size",
        submenu: makeSizeMenu(for: session, identifierPrefix: prefix, isEnabled: isActive),
        isEnabled: isActive
      ))
  }

  private func makeStopItem(for session: PiPSession, identifierPrefix prefix: String) -> NSMenuItem
  {
    let isCapturing: Bool
    switch session.state {
    case .selecting, .starting, .running, .suspended:
      isCapturing = true
    case .idle, .stopped, .failed:
      isCapturing = false
    }
    return makeMenuItem(
      title: L10n.string("menu.stop"),
      action: #selector(stopCaptureFromMenu(_:)),
      identifier: prefix + "stop",
      isEnabled: !isTerminating && isCapturing,
      session: session
    )
  }

  private func makeFrameRateMenu(
    for session: PiPSession, identifierPrefix prefix: String, isEnabled: Bool
  ) -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    for rate in FrameRate.allCases {
      let item = makeMenuItem(
        title: L10n.format("menu.frameRateValue", rate.framesPerSecond),
        action: #selector(selectFrameRateFromMenu(_:)),
        identifier: prefix + "frame-rate-\(rate.framesPerSecond)",
        isEnabled: isEnabled,
        session: session
      )
      item.tag = rate.rawValue
      item.state = rate == session.frameRate ? .on : .off
      menu.addItem(item)
    }
    return menu
  }

  private func makeOpacityMenu(
    for session: PiPSession, identifierPrefix prefix: String, isEnabled: Bool
  ) -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    for value in Self.opacityPresets {
      let clamped = min(
        max(value, AppSettings.opacityRange.lowerBound), AppSettings.opacityRange.upperBound)
      let percent = Int((clamped * 100).rounded())
      let item = makeMenuItem(
        title: L10n.format("menu.opacityValue", percent),
        action: #selector(selectOpacityFromMenu(_:)),
        identifier: prefix + "opacity-\(percent)",
        isEnabled: isEnabled,
        session: session,
        value: clamped
      )
      if abs(session.opacity - clamped) < 0.001 {
        item.state = .on
      }
      menu.addItem(item)
    }
    return menu
  }

  private func makeSizeMenu(
    for session: PiPSession, identifierPrefix prefix: String, isEnabled: Bool
  ) -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    for preset in Self.sizePresets {
      menu.addItem(
        makeMenuItem(
          title: L10n.string(preset.key),
          action: #selector(applySizePresetFromMenu(_:)),
          identifier: prefix + preset.identifier,
          isEnabled: isEnabled,
          session: session,
          value: preset.videoWidth
        ))
    }
    menu.addItem(.separator())
    menu.addItem(
      makeMenuItem(
        title: L10n.string("menu.sizeCustom"),
        action: #selector(customSizeFromMenu(_:)),
        identifier: prefix + "size-custom",
        isEnabled: isEnabled,
        session: session
      ))
    return menu
  }

  // MARK: - Choose Window submenu

  /// Lists capturable windows. The list is fetched asynchronously each time
  /// the submenu opens; a disabled "Loading…" row stands in until it arrives.
  private func populateWindowMenu(_ menu: WindowMenu) {
    windowMenuTask?.cancel()
    windowMenuTask = nil
    activeWindowMenu = menu
    menu.removeAllItems()
    let prefix = menu.identifierPrefix

    if ScreenCapturePermission.isGranted {
      menu.addItem(
        makeDisabledItem(
          title: L10n.string("menu.loadingWindows"),
          identifier: prefix + "windows-loading"
        ))
      windowMenuTask = Task { @MainActor [weak self, weak menu] in
        let windows: [CapturableWindow]?
        do {
          windows = try await WindowCatalog.fetch()
        } catch WindowCatalogError.permissionDenied {
          windows = nil
        } catch {
          windows = []
        }
        guard let self, let menu, !Task.isCancelled, menu === self.activeWindowMenu else { return }
        self.windowMenuTask = nil
        self.replaceWindowItems(in: menu, with: windows)
      }
    } else {
      menu.addItem(makePermissionItem(in: menu))
    }

    menu.addItem(.separator())
    menu.addItem(
      makeMenuItem(
        title: L10n.string("menu.useSystemPicker"),
        action: #selector(chooseWindowFromMenu(_:)),
        identifier: prefix + "use-system-picker",
        isEnabled: !isTerminating,
        session: menu.session
      ))
  }

  /// Replaces every row above the separator; `nil` means permission is missing.
  private func replaceWindowItems(in menu: WindowMenu, with windows: [CapturableWindow]?) {
    while let first = menu.items.first, !first.isSeparatorItem {
      menu.removeItem(first)
    }

    var items: [NSMenuItem] = []
    if let windows {
      if windows.isEmpty {
        items.append(
          makeDisabledItem(
            title: L10n.string("menu.noWindows"),
            identifier: menu.identifierPrefix + "windows-empty"
          ))
      }
      var icons: [pid_t: NSImage] = [:]
      for window in windows {
        let icon = icons[window.processID] ?? Self.appIcon(for: window.processID)
        icons[window.processID] = icon
        items.append(contentsOf: makeWindowItems(for: window, icon: icon, in: menu))
      }
    } else {
      items.append(makePermissionItem(in: menu))
    }

    for (index, item) in items.enumerated() {
      menu.insertItem(item, at: index)
    }
    menu.update()
  }

  /// A window row plus its ⌥ alternate that also enters region selection.
  private func makeWindowItems(
    for window: CapturableWindow, icon: NSImage?, in menu: WindowMenu
  ) -> [NSMenuItem] {
    let title = window.title.isEmpty ? window.appName : "\(window.appName) — \(window.title)"
    let prefix = menu.identifierPrefix

    let pick = makeMenuItem(
      title: title,
      action: #selector(pickWindowFromMenu(_:)),
      identifier: prefix + "window.\(window.id)",
      isEnabled: !isTerminating,
      session: menu.session,
      value: window.id
    )
    pick.image = icon
    pick.keyEquivalentModifierMask = []

    let regionTitle = L10n.format("menu.windowRegion", title)
    let region = makeMenuItem(
      title: regionTitle,
      action: #selector(pickWindowRegionFromMenu(_:)),
      identifier: prefix + "window-region.\(window.id)",
      isEnabled: !isTerminating,
      session: menu.session,
      value: window.id
    )
    region.image = icon
    region.keyEquivalentModifierMask = [.option]
    region.isAlternate = true

    return [pick, region]
  }

  private func makePermissionItem(in menu: WindowMenu) -> NSMenuItem {
    makeMenuItem(
      title: L10n.string("menu.allowScreenRecording"),
      action: #selector(requestScreenRecordingFromMenu(_:)),
      identifier: menu.identifierPrefix + "allow-screen-recording",
      isEnabled: !isTerminating,
      session: menu.session
    )
  }

  private static func appIcon(for processID: pid_t) -> NSImage? {
    guard let source = NSRunningApplication(processIdentifier: processID)?.icon,
      let icon = source.copy() as? NSImage
    else { return nil }
    icon.size = NSSize(width: 16, height: 16)
    return icon
  }

  // MARK: - Item factories

  /// With `session`, the item's `representedObject` is a `PiPMenuTarget`
  /// carrying that PiP and `value`.
  private func makeMenuItem(
    title: String, action: Selector, identifier: String, isEnabled: Bool = true,
    session: PiPSession? = nil, value: Any? = nil
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    item.isEnabled = isEnabled
    item.identifier = NSUserInterfaceItemIdentifier(identifier)
    item.setAccessibilityLabel(title)
    item.setAccessibilityIdentifier(identifier)
    if let session {
      item.representedObject = PiPMenuTarget(session: session, value: value)
    }
    return item
  }

  private func makeSubmenuItem(
    title: String, identifier: String, submenu: NSMenu, isEnabled: Bool
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.isEnabled = isEnabled
    item.identifier = NSUserInterfaceItemIdentifier(identifier)
    item.setAccessibilityLabel(title)
    item.setAccessibilityIdentifier(identifier)
    item.submenu = submenu
    return item
  }

  private func makeDisabledItem(title: String, identifier: String) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.isEnabled = false
    item.identifier = NSUserInterfaceItemIdentifier(identifier)
    item.setAccessibilityLabel(title)
    item.setAccessibilityIdentifier(identifier)
    return item
  }

  // MARK: - Actions

  /// The PiP a per-PiP item targets, with the item's value. `nil` while
  /// terminating or once that PiP has been removed (a menu built before the
  /// removal may still be open).
  private func menuTarget(_ sender: Any?) -> (session: PiPSession, value: Any?)? {
    guard !isTerminating,
      let target = (sender as? NSMenuItem)?.representedObject as? PiPMenuTarget,
      let session = target.session, manager.contains(session)
    else { return nil }
    return (session, target.value)
  }

  @objc private func newPiPFromMenu(_ sender: Any?) {
    guard !isTerminating else { return }
    manager.newSession()
  }

  @objc private func chooseWindowFromMenu(_ sender: Any?) {
    menuTarget(sender)?.session.chooseWindow()
  }

  @objc private func pickWindowFromMenu(_ sender: Any?) {
    guard let target = menuTarget(sender), let windowID = target.value as? CGWindowID else {
      return
    }
    target.session.pickWindow(windowID, region: false)
  }

  @objc private func pickWindowRegionFromMenu(_ sender: Any?) {
    guard let target = menuTarget(sender), let windowID = target.value as? CGWindowID else {
      return
    }
    // Region selection needs the panel to take mouse input.
    setClickThrough(false)
    target.session.pickWindow(windowID, region: true)
  }

  @objc private func requestScreenRecordingFromMenu(_ sender: Any?) {
    menuTarget(sender)?.session.requestScreenRecordingPermission()
  }

  @objc private func showPanelFromMenu(_ sender: Any?) {
    menuTarget(sender)?.session.show()
  }

  @objc private func selectRegionFromMenu(_ sender: Any?) {
    guard let target = menuTarget(sender) else { return }
    // Region selection needs the panel to take mouse input.
    setClickThrough(false)
    target.session.beginCrop()
  }

  @objc private func resetRegionFromMenu(_ sender: Any?) {
    menuTarget(sender)?.session.resetCrop()
  }

  @objc private func selectFrameRateFromMenu(_ sender: NSMenuItem) {
    guard let target = menuTarget(sender), let rate = FrameRate(rawValue: sender.tag) else {
      return
    }
    target.session.setFrameRate(rate)
  }

  @objc private func selectOpacityFromMenu(_ sender: Any?) {
    guard let target = menuTarget(sender), let value = target.value as? Double else { return }
    target.session.setOpacity(value)
  }

  @objc private func rotateFromMenu(_ sender: Any?) {
    menuTarget(sender)?.session.rotate()
  }

  @objc private func applySizePresetFromMenu(_ sender: Any?) {
    guard let target = menuTarget(sender), let videoWidth = target.value as? CGFloat else {
      return
    }
    target.session.applyPreset(videoWidth: videoWidth)
  }

  @objc private func customSizeFromMenu(_ sender: Any?) {
    guard let target = menuTarget(sender) else { return }
    // Size editing needs the panel to take mouse and keyboard input.
    setClickThrough(false)
    target.session.beginCustomSizeEditing()
  }

  @objc private func stopCaptureFromMenu(_ sender: Any?) {
    menuTarget(sender)?.session.stopCapture()
  }

  @objc private func closePiPFromMenu(_ sender: Any?) {
    guard let target = menuTarget(sender) else { return }
    manager.close(target.session)
  }

  @objc private func toggleClickThroughFromMenu(_ sender: Any?) {
    toggleClickThrough()
  }

  @objc private func closeAllFromMenu(_ sender: Any?) {
    guard !isTerminating else { return }
    manager.closeAll()
  }

  @objc private func showSettingsFromMenu(_ sender: Any?) {
    guard !isTerminating else { return }
    let controller =
      settingsWindowController ?? SettingsWindowController(settings: settings)
    settingsWindowController = controller
    controller.show()
  }

  @objc private func quitFromMenu(_ sender: Any?) {
    guard !isTerminating else { return }
    NSApp.terminate(nil)
  }
}

/// `representedObject` of a per-PiP menu item: the PiP it acts on (weak, so
/// an open menu never keeps a removed PiP alive) and the item's value.
@MainActor
private final class PiPMenuTarget: NSObject {
  weak var session: PiPSession?
  let value: Any?

  init(session: PiPSession, value: Any?) {
    self.session = session
    self.value = value
  }
}

/// A PiP's "Choose Window" submenu; `AppController` fills it when it opens.
private final class WindowMenu: NSMenu {
  weak var session: PiPSession?
  /// Prefix of every item identifier, e.g. "pip.menu." or "pip.menu.pip-2.".
  var identifierPrefix = "pip.menu."
}
