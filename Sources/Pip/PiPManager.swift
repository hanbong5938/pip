import AppKit
import Foundation

/// Owns every picture-in-picture, ordered by creation.
///
/// Invariants:
/// - Once a PiP exists there is always at least one: closing the last
///   remaining PiP stops its capture and only hides it, so "Show PiP" and
///   reopen keep working. Closing any other PiP removes it.
/// - A closed panel always has its capture stopped, so the only PiP whose
///   panel can be hidden is that kept last one.
/// - Each PiP holds a slot that keys its remembered frame: slot 0 autosaves
///   as "pip.panel" (the single-PiP name, so existing frames carry over),
///   slot n as "pip.panel.<n>". A removed PiP keeps its slot until its capture
///   has stopped and it is released, so two live panels never share an
///   autosave name; the lowest free slot is reused.
/// - Click-through is app-wide: every existing and future PiP follows
///   `isClickThrough`.
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

  /// Shows a new PiP with the in-app window list, cascaded from the newest
  /// visible panel unless its slot remembers a frame. A hidden sole PiP is
  /// shown instead of adding a second one next to it.
  @discardableResult
  func newSession() -> PiPSession? {
    guard !isShuttingDown else { return nil }
    if entries.count == 1, let only = entries.first?.session, !only.isPanelOpen {
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
    session.show()
    return session
  }

  /// Closes one PiP through its panel's close path (stops the capture, then
  /// removes it unless it is the last one).
  func close(_ session: PiPSession) {
    guard !isShuttingDown, contains(session) else { return }
    session.close()
  }

  /// Stops and removes every PiP except the one with the lowest slot, which
  /// is stopped and hidden.
  func closeAll() {
    guard !isShuttingDown, let keeper = entries.min(by: { $0.slot < $1.slot }) else { return }
    let others = entries.filter { $0.session !== keeper.session }
    entries = [keeper]
    for entry in others {
      retire(entry)
    }
    keeper.session.close()
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

  /// Runs after the panel's close path has requested the capture stop.
  private func panelClosed(_ session: PiPSession) {
    guard !isShuttingDown, entries.count > 1,
      let index = entries.firstIndex(where: { $0.session === session })
    else { return }
    retire(entries.remove(at: index))
  }

  /// Hides the panel (stopping the capture) and releases the PiP once the
  /// stop has completed and its renderer is shut down.
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
