import Carbon.HIToolbox
import Foundation

/// System-wide hot key backed by Carbon `RegisterEventHotKey`.
///
/// Unlike `NSEvent.addGlobalMonitorForEvents`, Carbon hot keys need no
/// Accessibility permission and consume the key press, so it is not delivered to
/// the frontmost app.
///
/// A single Carbon event handler is installed on the application event target
/// the first time any hot key registers and stays installed for the process
/// lifetime. It routes `kEventHotKeyPressed` to the live instance whose
/// `EventHotKeyID.id` matches. Instances are held weakly by the registry, so the
/// owner controls lifetime; dropping the last reference unregisters the key.
@MainActor
final class GlobalHotKey {
  /// ⌃⌥P: toggles click-through on the PiP panel.
  nonisolated static let clickThroughKeyCode = UInt32(kVK_ANSI_P)
  nonisolated static let clickThroughModifiers = UInt32(controlKey | optionKey)

  /// Four-char code `'PiPk'` tagging every hot key this app registers, so the
  /// shared handler ignores hot key events it does not own.
  nonisolated fileprivate static let signature: OSType = {
    "PiPk".utf8.reduce(OSType(0)) { ($0 << 8) | OSType($1) }
  }()

  private struct WeakEntry {
    weak var hotKey: GlobalHotKey?
  }

  private static var registry: [UInt32: WeakEntry] = [:]
  private static var nextID: UInt32 = 1
  private static var eventHandlerRef: EventHandlerRef?

  private let id: UInt32
  private let handler: @MainActor () -> Void
  /// Only mutated on the main actor; `nonisolated(unsafe)` so `deinit` (which is
  /// nonisolated but in practice runs on the main thread for this main-actor
  /// object) can release the Carbon registration.
  private nonisolated(unsafe) var hotKeyRef: EventHotKeyRef?

  /// Registers `keyCode` (a `kVK_*` virtual key code) with Carbon `modifiers`
  /// (`cmdKey`, `optionKey`, `controlKey`, `shiftKey`). Returns `nil` when the
  /// shared handler cannot be installed or the combination is already taken.
  init?(keyCode: UInt32, modifiers: UInt32, handler: @escaping @MainActor () -> Void) {
    guard Self.installEventHandlerIfNeeded() else { return nil }

    let id = Self.nextID
    Self.nextID &+= 1
    if Self.nextID == 0 { Self.nextID = 1 }

    var ref: EventHotKeyRef?
    let status = RegisterEventHotKey(
      keyCode,
      modifiers,
      EventHotKeyID(signature: Self.signature, id: id),
      GetApplicationEventTarget(),
      0,
      &ref
    )
    guard status == noErr, let ref else { return nil }

    self.id = id
    self.handler = handler
    self.hotKeyRef = ref
    Self.registry[id] = WeakEntry(hotKey: self)
  }

  deinit {
    // Registry entry is weak and pruned lazily on dispatch; only the Carbon
    // registration must be released here so the key combination is freed.
    if let hotKeyRef {
      UnregisterEventHotKey(hotKeyRef)
    }
  }

  /// Releases the hot key. Safe to call more than once.
  func unregister() {
    guard let hotKeyRef else { return }
    self.hotKeyRef = nil
    UnregisterEventHotKey(hotKeyRef)
    Self.registry[id] = nil
  }

  fileprivate static func dispatch(id: UInt32) -> Bool {
    guard let entry = registry[id] else { return false }
    guard let hotKey = entry.hotKey, hotKey.hotKeyRef != nil else {
      registry[id] = nil
      return false
    }
    hotKey.handler()
    return true
  }

  private static func installEventHandlerIfNeeded() -> Bool {
    if eventHandlerRef != nil { return true }
    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed)
    )
    var ref: EventHandlerRef?
    let status = InstallEventHandler(
      GetApplicationEventTarget(),
      globalHotKeyEventHandler,
      1,
      &eventType,
      nil,
      &ref
    )
    guard status == noErr, let ref else { return false }
    eventHandlerRef = ref
    return true
  }
}

/// Carbon callback for `kEventHotKeyPressed`.
///
/// Handlers installed on `GetApplicationEventTarget()` are invoked by the main
/// run loop's event dispatch, i.e. always on the main thread, which makes
/// `MainActor.assumeIsolated` sound here.
private func globalHotKeyEventHandler(
  _ callRef: EventHandlerCallRef?,
  _ event: EventRef?,
  _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
  guard let event else { return OSStatus(eventNotHandledErr) }

  var hotKeyID = EventHotKeyID()
  let status = GetEventParameter(
    event,
    EventParamName(kEventParamDirectObject),
    EventParamType(typeEventHotKeyID),
    nil,
    MemoryLayout<EventHotKeyID>.size,
    nil,
    &hotKeyID
  )
  guard status == noErr, hotKeyID.signature == GlobalHotKey.signature else {
    return OSStatus(eventNotHandledErr)
  }

  let id = hotKeyID.id
  let handled = MainActor.assumeIsolated {
    GlobalHotKey.dispatch(id: id)
  }
  return handled ? noErr : OSStatus(eventNotHandledErr)
}
