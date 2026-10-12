import AppKit
import Darwin
import Foundation

private struct SmokeFailure: Error, CustomStringConvertible {
  let description: String
}

@MainActor
private func require(_ condition: Bool, _ description: String) throws {
  guard condition else { throw SmokeFailure(description: description) }
}

@MainActor
private func pass(_ description: String) {
  print("PASS: \(description)")
}

@MainActor
private func panel(named autosave: String) throws -> NSPanel {
  guard
    let panel = NSApplication.shared.windows.first(where: {
      $0 is NSPanel && $0.frameAutosaveName == autosave
    }) as? NSPanel
  else {
    throw SmokeFailure(description: "AppKit panel \(autosave) not found")
  }
  return panel
}

@MainActor
private func isOff(_ session: PiPSession) -> Bool {
  guard !session.hasCaptureWork, !session.hasRetainedSetup, !session.canResumeCapture,
    !session.canApplySavedSetup, !session.canRememberSetup
  else { return false }
  switch session.state {
  case .idle, .stopped, .failed: return true
  case .selecting, .starting, .running, .suspended: return false
  }
}

@MainActor
private func settleStop(_ session: PiPSession) async throws {
  for _ in 0..<60 {
    if !session.isStoppingCapture { return }
    try await Task.sleep(for: .milliseconds(50))
  }
  throw SmokeFailure(description: "idle capture stop did not settle within three seconds")
}

// NSWindow persists frame autosaves in this CLI's preference domain, not Pip's.
@MainActor
private func clearPanelAutosaves() {
  for index in 0..<8 {
    let name = index == 0 ? "pip.panel" : "pip.panel.\(index)"
    UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(name)")
  }
}

private final class GenerationRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var generations: [UInt64] = []

  func record(_ generation: UInt64) {
    lock.lock()
    generations.append(generation)
    lock.unlock()
  }

  func snapshot() -> [UInt64] {
    lock.lock()
    defer { lock.unlock() }
    return generations
  }
}

@MainActor
private func smoke() async throws {
  let app = NSApplication.shared
  _ = app.setActivationPolicy(.accessory)
  clearPanelAutosaves()
  defer { clearPanelAutosaves() }

  // The two typed stores never touch the app's normal preference domain.
  let suite = "PipNativeStateSmoke.\(UUID().uuidString)"
  guard let isolatedDefaults = UserDefaults(suiteName: suite) else {
    throw SmokeFailure(description: "cannot create isolated preferences suite")
  }
  defer { isolatedDefaults.removePersistentDomain(forName: suite) }
  let settings = AppSettings(defaults: isolatedDefaults)
  let savedStore = SavedSetupStore(defaults: isolatedDefaults)
  let recipe = SavedSetup(
    appBundleIdentifier: "dev.example.smoke", appName: "Example",
    crop: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.6),
    sourceSize: CGSize(width: 1024, height: 768),
    frameRate: FrameRate.fps15.rawValue, opacity: 0.55, rotationDegrees: 90)
  try require(recipe != nil, "valid standalone recipe creation")
  try require(savedStore.savedSetup == nil, "isolated recipe starts empty")
  try require(savedStore.save(recipe!), "explicit standalone recipe save")
  try require(
    SavedSetupStore(defaults: isolatedDefaults).savedSetup == recipe,
    "saved recipe visible from fresh store, not a capture authorization")
  pass("UUID-isolated AppSettings and SavedSetupStore; explicit recipe persists independently")

  let manager = PiPManager(settings: settings)
  guard let first = manager.newSession(show: false) else {
    throw SmokeFailure(description: "cannot create initial PiP")
  }
  let firstPanel = try panel(named: "pip.panel")
  try require(
    manager.sessions.count == 1 && !first.isPanelOpen && !firstPanel.isVisible && isOff(first),
    "initial empty PiP is hidden and off even with saved recipe")
  first.show()
  try require(
    first.isPanelOpen && firstPanel.isVisible && isOff(first),
    "show must only show the panel, never select/start a source")
  manager.showAll()
  try require(firstPanel.isVisible && isOff(first), "showAll must not start capture or picker")
  pass("initial new/show/showAll are panel-only; no picker, capture, or automatic recipe restore")

  first.setFrameRate(.fps15)
  first.setOpacity(0.55)
  first.rotate()
  manager.setClickThrough(true)
  try require(
    manager.isClickThrough && first.isClickThrough && firstPanel.ignoresMouseEvents,
    "click-through propagates to actual panel")
  first.hide()
  try require(
    !first.isPanelOpen && !firstPanel.isVisible && manager.contains(first),
    "hide keeps session but orders panel out")
  try await settleStop(first)
  first.show()
  try require(
    first.isPanelOpen && firstPanel.isVisible && isOff(first)
      && first.frameRate == .fps15 && first.opacity == 0.55
      && first.rotation == .clockwise90 && first.isClickThrough
      && firstPanel.ignoresMouseEvents && firstPanel.alphaValue == 0.55,
    "hide/show preserves display settings and global click-through without capture")
  manager.showAll()
  try require(
    firstPanel.isVisible && isOff(first) && manager.isClickThrough,
    "repeated showAll retains off state and click-through")
  pass("hide/show preserves FPS, opacity, rotation, panel click-through; off remains off")

  guard let second = manager.newSession() else {
    throw SmokeFailure(description: "cannot create second PiP")
  }
  let secondPanel = try panel(named: "pip.panel.1")
  try require(
    second !== first && secondPanel.isVisible && second.isClickThrough
      && secondPanel.ignoresMouseEvents && isOff(second),
    "second PiP is independently visible and inherits global click-through")
  second.setFrameRate(.fps60)
  second.setOpacity(0.8)
  second.rotate()
  second.rotate()
  try require(
    second.frameRate == .fps60 && second.opacity == 0.8
      && second.rotation == .upsideDown && secondPanel.alphaValue == 0.8
      && first.frameRate == .fps15 && first.opacity == 0.55
      && first.rotation == .clockwise90 && manager.isClickThrough,
    "second PiP display settings are independent of first")
  first.hide()
  try await settleStop(first)
  try require(
    manager.sessions.count == 2 && manager.contains(first) && manager.contains(second)
      && !firstPanel.isVisible && secondPanel.isVisible,
    "hidden session still owns its manager slot")
  manager.showAll()
  try require(
    firstPanel.isVisible && secondPanel.isVisible && isOff(first) && isOff(second)
      && first.frameRate == .fps15 && first.rotation == .clockwise90
      && second.frameRate == .fps60 && second.rotation == .upsideDown,
    "showAll reopens hidden session without capture or cross-session setting changes")
  first.hide()
  manager.close(first)
  try require(
    !manager.contains(first) && manager.contains(second) && !firstPanel.isVisible,
    "close removes hidden session and leaves visible peer intact")
  manager.close(first)
  first.close()
  try require(
    manager.sessions.count == 1 && manager.sessions[0] === second,
    "repeated close on closed session is idempotent")
  manager.close(second)
  try require(
    manager.sessions.count == 1 && manager.sessions[0] !== second
      && !secondPanel.isVisible && !manager.sessions[0].isPanelOpen
      && isOff(manager.sessions[0]) && manager.sessions[0].isClickThrough
      && manager.isClickThrough,
    "closing final session installs fresh hidden off keeper without changing global click-through")
  pass("multi-session hide versus terminal close, hidden close, idempotence, new keeper identity")

  guard let keeper = manager.sessions.first else {
    throw SmokeFailure(description: "missing keeper")
  }
  guard let reused = manager.newSession() else {
    throw SmokeFailure(description: "keeper reuse failed")
  }
  try require(
    reused === keeper && reused.isPanelOpen && isOff(reused),
    "only hidden empty keeper is reused; it remains off")
  guard let third = manager.newSession() else {
    throw SmokeFailure(description: "cannot create PiP alongside keeper")
  }
  keeper.hide()
  try await settleStop(keeper)
  let beforeCloseAll = manager.sessions
  try require(
    beforeCloseAll.count == 2 && beforeCloseAll.contains(where: { $0 === keeper })
      && beforeCloseAll.contains(where: { $0 === third }),
    "hidden and visible sessions present before closeAll")
  manager.closeAll()
  try require(
    manager.sessions.count == 1 && !manager.sessions[0].isPanelOpen
      && isOff(manager.sessions[0]) && manager.sessions[0].isClickThrough
      && manager.isClickThrough
      && beforeCloseAll.allSatisfy { old in !manager.contains(old) && manager.sessions[0] !== old },
    "closeAll removes hidden and visible sessions, retaining global click-through")
  pass("closeAll includes hidden sessions and creates distinct hidden off keeper")

  guard let shutdownKeeper = manager.sessions.first else {
    throw SmokeFailure(description: "missing shutdown keeper")
  }
  // Stop immediately followed by selection is a user action while stop is pending.
  // Its public guard must suppress the picker and list resolve (no source ID is fabricated).
  shutdownKeeper.show()
  shutdownKeeper.stopCapture()
  shutdownKeeper.chooseWindow()
  shutdownKeeper.pickWindow(0, region: false)
  try require(
    shutdownKeeper.isStoppingCapture && !shutdownKeeper.canChooseSource
      && !shutdownKeeper.hasRetainedSetup && !shutdownKeeper.canResumeCapture,
    "selection immediately after stop cannot revive capture or open picker")
  try await settleStop(shutdownKeeper)
  try require(
    isOff(shutdownKeeper) && shutdownKeeper.isPausedByUser,
    "settled user stop stays off")
  pass("stop immediately followed by explicit picker/list selection stays off through settling")

  shutdownKeeper.hide()
  try await settleStop(shutdownKeeper)
  manager.beginShutdown()
  let shutdownCount = manager.sessions.count
  shutdownKeeper.show()
  shutdownKeeper.chooseWindow()
  shutdownKeeper.pickWindow(0, region: false)
  shutdownKeeper.restoreSavedSetup(from: savedStore)
  shutdownKeeper.resumeCapture()
  manager.showAll()
  manager.close(shutdownKeeper)
  manager.closeAll()
  try require(
    manager.newSession() == nil && manager.sessions.count == shutdownCount
      && manager.contains(shutdownKeeper) && !shutdownKeeper.isPanelOpen
      && !shutdownKeeper.canChooseSource && !shutdownKeeper.canResumeCapture
      && !shutdownKeeper.canApplySavedSetup && !shutdownKeeper.hasRetainedSetup,
    "beginShutdown suppresses new/show/picker/list/restore and preserves hidden panel")

  let freshManager = PiPManager(settings: AppSettings(defaults: isolatedDefaults))
  guard let fresh = freshManager.newSession(show: false) else {
    throw SmokeFailure(description: "fresh manager cannot create PiP")
  }
  try require(isOff(fresh) && !fresh.isPanelOpen, "fresh manager starts off")
  await manager.shutdownAll()
  try require(
    isOff(fresh) && freshManager.contains(fresh),
    "retiring sessions from old manager cannot mutate fresh manager")
  await freshManager.shutdownAll()
  pass("synchronous shutdown gate and old-manager retirement leave fresh manager off")

  // CaptureSession's actual generation reset and state publishing, with no
  // SCStream/picker callbacks fabricated. A live late callback requires a real source.
  let generations = GenerationRecorder()
  let capture = CaptureSession(onFrame: { _ in }, onReset: { generations.record($0) })
  var observedStates: [CaptureState] = []
  capture.onStateChange = { observedStates.append($0) }
  try require(
    !capture.hasCaptureWork && capture.sourceIdentity == nil,
    "fresh CaptureSession owns no stream or source")
  capture.invalidateForUserStop()
  let firstReset = generations.snapshot()
  try require(firstReset.count == 1, "first user invalidation must advance frame generation once")
  capture.invalidateForUserStop()
  capture.chooseWindow()  // Must be blocked before the asynchronous stop installs stopTask.
  try require(
    generations.snapshot() == firstReset && observedStates.isEmpty
      && !capture.hasCaptureWork && capture.sourceIdentity == nil,
    "repeated invalidation is idempotent and selection cannot present picker")
  await capture.stop()
  try require(
    observedStates == [.stopped(L10n.string("capture.stopped"))]
      && generations.snapshot() == firstReset && !capture.hasCaptureWork,
    "real stop publishes stopped without resetting frame generation twice")
  capture.invalidateForUserStop()
  let secondReset = generations.snapshot()
  try require(
    secondReset.count == 2 && secondReset[1] > secondReset[0],
    "later explicit stop has strictly newer generation")
  await capture.stop()
  try require(
    !capture.hasCaptureWork && capture.sourceIdentity == nil,
    "repeated stopped CaptureSession cannot retain a stream or source")
  pass(
    "CaptureSession real user-stop generation, idempotent invalidation, stop state and picker gate")

  savedStore.delete()
  try require(savedStore.savedSetup == nil, "explicit saved recipe deletion")
  pass(
    "no live source available: live capture/return/crop/permission, picker callbacks and media not exercised"
  )
}

@main
private struct PipNativeStateSmoke {
  @MainActor
  static func main() async {
    do {
      try await smoke()
      print("PASS: native state smoke complete")
    } catch {
      FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
      exit(EXIT_FAILURE)
    }
  }
}
