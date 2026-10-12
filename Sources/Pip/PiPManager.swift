import AppKit
import Foundation

/// Owns all PiPs, including hidden paused sessions. A terminal close removes
/// a session unless it is the sole empty keeper; a hide never removes it.
/// Slots stay reserved until retired renderers finish shutting down.
/// Click-through remains an app-wide explicit setting.
@MainActor
final class PiPManager {
  private struct Entry {
    let session: PiPSession
    let slot: Int
  }

  private(set) var isClickThrough = false

  /// Live PiPs in creation order; removed PiPs leave immediately.
  var sessions: [PiPSession] {
    entries.map(\.session)
  }

  private let settings: AppSettings
  private var entries: [Entry] = []
  /// Removed PiPs whose capture is still stopping, by slot. Each task holds
  /// its session until `shutdown()` returns, then frees the slot.
  private var retiring: [Int: Task<Void, Never>] = [:]
  /// Set synchronously by `beginShutdown()`; no PiP is created, removed, or
  /// shown afterwards.
  private var isShuttingDown = false

  init(settings: AppSettings) {
    self.settings = settings
  }

  func contains(_ session: PiPSession) -> Bool {
    entries.contains { $0.session === session }
  }

  /// Create a new PiP, reusing only a hidden, empty sole keeper.
  @discardableResult
  func newSession(show: Bool = true) -> PiPSession? {
    guard !isShuttingDown else { return nil }
    if show, entries.count == 1, let only = entries.first?.session,
      !only.isPanelOpen, !only.hasRetainedSetup, !only.hasCaptureWork
    {
      only.show()
      return only
    }

    let slot = lowestFreeSlot()
    let cascadeFrom = entries.last(where: { $0.session.isPanelOpen })?.session.panelFrame
    let session = PiPSession(
      settings: settings,
      autosaveName: Self.autosaveName(forSlot: slot),
      cascadeFrom: cascadeFrom
    )
    session.setClickThrough(isClickThrough)
    session.onPanelClosed = { [weak self, weak session] in
      guard let self, let session else { return }
      self.panelClosed(session)
    }
    entries.append(Entry(session: session, slot: slot))
    if show { session.show() }
    return session
  }

  /// Closes one PiP terminally; a hidden session still closes.
  func close(_ session: PiPSession) {
    guard !isShuttingDown, contains(session) else { return }
    session.close()
  }

  /// Closes all PiPs, including hidden sessions; installs a fresh empty keeper.
  func closeAll() {
    guard !isShuttingDown, !entries.isEmpty else { return }
    let old = entries
    entries = []
    for entry in old { retire(entry) }
    _ = newSession(show: false)
  }

  /// Brings back every panel (reopen); creates one if none exists.
  func showAll() {
    guard !isShuttingDown else { return }
    guard !entries.isEmpty else {
      newSession()
      return
    }
    for entry in entries {
      entry.session.show()
    }
  }

  func setClickThrough(_ enabled: Bool) {
    guard !isShuttingDown else { return }
    isClickThrough = enabled
    for entry in entries {
      entry.session.setClickThrough(enabled)
    }
  }

  /// Suppresses panel-originated actions on every PiP immediately. Call
  /// synchronously when termination begins; `shutdownAll()` runs later.
  func beginShutdown() {
    isShuttingDown = true
    for entry in entries {
      entry.session.beginShutdown()
    }
  }

  /// Stops every capture (live and still-retiring PiPs) in parallel and shuts
  /// the renderers down; returns once no stream is left.
  func shutdownAll() async {
    beginShutdown()
    let sessions = entries.map(\.session)
    let pending = Array(retiring.values)
    await withTaskGroup(of: Void.self) { group in
      for session in sessions {
        group.addTask {
          await session.shutdown()
        }
      }
      for task in pending {
        group.addTask {
          await task.value
        }
      }
    }
  }

  /// Runs once after a terminal close, including a hidden close.
  private func panelClosed(_ session: PiPSession) {
    guard !isShuttingDown,
      let index = entries.firstIndex(where: { $0.session === session })
    else { return }
    let wasLast = entries.count == 1
    retire(entries.remove(at: index))
    if wasLast { _ = newSession(show: false) }
  }

  /// Releases a terminally closed PiP once its stop and renderer shutdown finish.
  private func retire(_ entry: Entry) {
    let session = entry.session
    let slot = entry.slot
    session.onPanelClosed = nil
    session.close()
    retiring[slot] = Task { @MainActor [weak self] in
      await session.shutdown()
      self?.retiring[slot] = nil
    }
  }

  private func lowestFreeSlot() -> Int {
    let used = Set(entries.map(\.slot)).union(retiring.keys)
    var slot = 0
    while used.contains(slot) {
      slot += 1
    }
    return slot
  }

  private static func autosaveName(forSlot slot: Int) -> String {
    slot == 0 ? "pip.panel" : "pip.panel.\(slot)"
  }
}
