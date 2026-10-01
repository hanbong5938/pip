import AppKit
import Foundation

@MainActor
final class AppController: NSObject, NSApplicationDelegate {
  private var renderer: FrameRenderer?
  private var panelController: FloatingPanelController?
  private var captureSession: CaptureSession?
  private var statusItem: NSStatusItem?
  private var rotateMenuItem: NSMenuItem?
  private var rotation: VideoRotation = .none
  private var terminationTask: Task<Void, Never>?
  private var isTerminating = false
  private var terminationReplySent = false
  private var rendererFailure: String?
  private var didFinishLaunching = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    guard !didFinishLaunching else { return }
    didFinishLaunching = true

    NSApp.setActivationPolicy(.accessory)
    createRendererAndPanel()
    createCaptureSession()
    createStatusItem()

    if let rendererFailure {
      panelController?.update(state: .failed(rendererFailure))
    } else {
      panelController?.update(state: .idle)
    }
    panelController?.show()
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if terminationReplySent {
      return .terminateNow
    }
    guard !isTerminating else {
      return .terminateCancel
    }

    isTerminating = true
    let session = captureSession
    let renderer = self.renderer
    terminationTask = Task { @MainActor [self] in
      await session?.stop()
      renderer?.shutdown()

      guard !terminationReplySent else { return }
      terminationReplySent = true
      NSApp.reply(toApplicationShouldTerminate: true)
      terminationTask = nil
    }
    return .terminateLater
  }

  // Relaunching from Finder/Spotlight/Raycast while the menu-bar app is running
  // only sends a reopen event, so bring back the panel the user closed.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    if !isTerminating {
      panelController?.show()
    }
    return false
  }

  private func createRendererAndPanel() {
    let candidateRenderer: FrameRenderer?
    do {
      candidateRenderer = try FrameRenderer()
    } catch {
      candidateRenderer = nil
      let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
      rendererFailure = detail.isEmpty ? "렌더러를 시작할 수 없습니다." : "렌더러 오류: \(detail)"
    }
    renderer = candidateRenderer

    let videoView: NSView
    if let candidateRenderer {
      videoView = candidateRenderer.view
    } else {
      let fallbackView = NSView(frame: .zero)
      fallbackView.wantsLayer = true
      fallbackView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
      videoView = fallbackView
    }

    let panel = FloatingPanelController(videoView: videoView)
    panel.onChooseWindow = { [weak self] in
      self?.chooseWindow()
    }
    panel.onClose = { [weak self] in
      self?.panelDidClose()
    }
    panelController = panel
  }

  private func createCaptureSession() {
    let renderer = self.renderer
    let session = CaptureSession(
      onFrame: { frame in
        renderer?.submit(frame)
      },
      onReset: { generation in
        renderer?.reset(generation: generation)
      }
    )
    session.onStateChange = { [weak self] state in
      self?.captureStateChanged(state)
    }
    captureSession = session
  }

  private func createStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let button = item.button {
      button.title = "PiP"
      button.setAccessibilityLabel("PiP 메뉴")
      button.setAccessibilityIdentifier("pip.status-item")
    }

    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.addItem(
      makeMenuItem(
        title: "창 선택",
        action: #selector(chooseWindowFromMenu(_:)),
        identifier: "pip.menu.choose-window"
      ))
    menu.addItem(
      makeMenuItem(
        title: "PiP 보이기",
        action: #selector(showPanelFromMenu(_:)),
        identifier: "pip.menu.show-panel"
      ))
    let rotateItem = makeMenuItem(
      title: Self.rotateMenuTitle(for: rotation),
      action: #selector(rotateFromMenu(_:)),
      identifier: "pip.menu.rotate"
    )
    menu.addItem(rotateItem)
    rotateMenuItem = rotateItem
    menu.addItem(.separator())
    menu.addItem(
      makeMenuItem(
        title: "중지",
        action: #selector(stopCaptureFromMenu(_:)),
        identifier: "pip.menu.stop"
      ))
    menu.addItem(
      makeMenuItem(
        title: "종료",
        action: #selector(quitFromMenu(_:)),
        identifier: "pip.menu.quit"
      ))
    item.menu = menu
    statusItem = item
  }

  private func makeMenuItem(title: String, action: Selector, identifier: String) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    item.identifier = NSUserInterfaceItemIdentifier(identifier)
    item.setAccessibilityLabel(title)
    item.setAccessibilityIdentifier(identifier)
    return item
  }

  private static func rotateMenuTitle(for rotation: VideoRotation) -> String {
    "화면 회전 (현재 \(rotation.degrees)°)"
  }

  @objc private func chooseWindowFromMenu(_ sender: Any?) {
    chooseWindow()
  }

  @objc private func showPanelFromMenu(_ sender: Any?) {
    guard !isTerminating else { return }
    panelController?.show()
  }

  // Rotation is display-only and session-scoped: it is not persisted and
  // survives choosing another window.
  @objc private func rotateFromMenu(_ sender: Any?) {
    guard !isTerminating else { return }
    let next = rotation.next
    if next.swapsDimensions != rotation.swapsDimensions {
      panelController?.swapVideoOrientation()
    }
    rotation = next
    renderer?.setRotation(next)

    let title = Self.rotateMenuTitle(for: next)
    rotateMenuItem?.title = title
    rotateMenuItem?.setAccessibilityLabel(title)
  }

  @objc private func stopCaptureFromMenu(_ sender: Any?) {
    guard !isTerminating else { return }
    requestCaptureStop()
  }

  @objc private func quitFromMenu(_ sender: Any?) {
    guard !isTerminating else { return }
    NSApp.terminate(nil)
  }

  private func chooseWindow() {
    guard !isTerminating else { return }
    guard renderer != nil else {
      if let rendererFailure {
        panelController?.update(state: .failed(rendererFailure))
      }
      panelController?.show()
      return
    }

    panelController?.show()
    captureSession?.chooseWindow()
  }

  private func panelDidClose() {
    guard !isTerminating else { return }
    requestCaptureStop()
  }

  private func requestCaptureStop() {
    Task { @MainActor [weak self] in
      guard let self else { return }
      await self.captureSession?.stop()
    }
  }

  private func captureStateChanged(_ state: CaptureState) {
    if let rendererFailure {
      panelController?.update(state: .failed(rendererFailure))
    } else {
      panelController?.update(state: state)
    }
  }
}
