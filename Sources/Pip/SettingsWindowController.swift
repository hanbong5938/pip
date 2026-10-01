import AppKit
import SwiftUI

/// The single settings window. Reused across `show()` calls; closing only
/// orders it out.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
  private let model: SettingsModel
  private var window: NSWindow?

  init(settings: AppSettings) {
    model = SettingsModel(settings: settings)
    super.init()
  }

  func show() {
    let window = self.window ?? makeWindow()
    if self.window == nil {
      self.window = window
      window.center()
    }
    model.reload()
    NSApp.activate()
    window.makeKeyAndOrderFront(nil)
  }

  /// Login item approval and preferences can change outside this window
  /// (System Settings, `defaults write`), so re-read whenever it is focused.
  func windowDidBecomeKey(_ notification: Notification) {
    model.reload()
  }

  private func makeWindow() -> NSWindow {
    let hostingController = NSHostingController(rootView: SettingsView(model: model))
    hostingController.sizingOptions = [.preferredContentSize]

    let window = NSWindow(contentViewController: hostingController)
    window.styleMask = [.titled, .closable]
    window.title = L10n.string("settings.title")
    window.isReleasedWhenClosed = false
    window.collectionBehavior.insert(.fullScreenNone)
    window.delegate = self
    window.setAccessibilityIdentifier("pip.settings.window")
    return window
  }
}

/// SwiftUI-facing mirror of `AppSettings` and the login item status. Every
/// setter writes through immediately; `reload()` re-reads the sources.
@MainActor
@Observable
private final class SettingsModel {
  private(set) var launchAtLogin = false
  private(set) var loginItemRequiresApproval = false
  private(set) var loginItemError: String?
  private(set) var autoCloseOnSourceClose = false
  private(set) var defaultFrameRate = FrameRate.fps30
  private(set) var defaultOpacity = 1.0
  private(set) var clickThroughHotKeyEnabled = true

  @ObservationIgnored private let settings: AppSettings
  /// Login item status when `loginItemError` was recorded; the error is
  /// cleared once the live status moves away from it.
  @ObservationIgnored private var loginItemErrorStatus: (enabled: Bool, requiresApproval: Bool)?

  init(settings: AppSettings) {
    self.settings = settings
    reload()
  }

  func reload() {
    let newLaunchAtLogin = LoginItem.isEnabled || LoginItem.requiresApproval
    let newRequiresApproval = LoginItem.requiresApproval
    if let status = loginItemErrorStatus,
      status.enabled != newLaunchAtLogin || status.requiresApproval != newRequiresApproval
    {
      loginItemError = nil
      loginItemErrorStatus = nil
    }
    launchAtLogin = newLaunchAtLogin
    loginItemRequiresApproval = newRequiresApproval
    autoCloseOnSourceClose = settings.autoCloseOnSourceClose
    defaultFrameRate = settings.defaultFrameRate
    defaultOpacity = settings.defaultOpacity
    clickThroughHotKeyEnabled = settings.clickThroughHotKeyEnabled
  }

  func setLaunchAtLogin(_ enabled: Bool) {
    do {
      try LoginItem.setEnabled(enabled)
      loginItemError = nil
    } catch {
      loginItemError = L10n.format("settings.launchAtLoginFailed", error.localizedDescription)
    }
    launchAtLogin = LoginItem.isEnabled || LoginItem.requiresApproval
    loginItemRequiresApproval = LoginItem.requiresApproval
    loginItemErrorStatus = loginItemError == nil ? nil : (launchAtLogin, loginItemRequiresApproval)
  }

  func setAutoCloseOnSourceClose(_ enabled: Bool) {
    settings.autoCloseOnSourceClose = enabled
    autoCloseOnSourceClose = settings.autoCloseOnSourceClose
  }

  func setDefaultFrameRate(_ rate: FrameRate) {
    settings.defaultFrameRate = rate
    defaultFrameRate = settings.defaultFrameRate
  }

  func setDefaultOpacity(_ value: Double) {
    settings.defaultOpacity = value
    defaultOpacity = settings.defaultOpacity
  }

  func setClickThroughHotKeyEnabled(_ enabled: Bool) {
    settings.clickThroughHotKeyEnabled = enabled
    clickThroughHotKeyEnabled = settings.clickThroughHotKeyEnabled
  }
}

private struct SettingsView: View {
  let model: SettingsModel

  var body: some View {
    Form {
      Section {
        Toggle(
          L10n.string("settings.launchAtLogin"),
          isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) })
        )
        .accessibilityIdentifier("pip.settings.launch-at-login")

        if model.loginItemRequiresApproval {
          HStack(alignment: .firstTextBaseline) {
            Text(L10n.string("settings.loginItemNeedsApproval"))
              .font(.footnote)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(L10n.string("settings.openLoginItems")) {
              LoginItem.openLoginItemsSettings()
            }
            .controlSize(.small)
            .accessibilityIdentifier("pip.settings.open-login-items")
          }
        }

        if let error = model.loginItemError {
          Label {
            Text(error)
              .fixedSize(horizontal: false, vertical: true)
          } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
              .symbolRenderingMode(.multicolor)
          }
          .font(.footnote)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("pip.settings.launch-at-login-error")
        }
      }

      Section(L10n.string("settings.section.pip")) {
        Toggle(
          L10n.string("settings.autoClose"),
          isOn: Binding(
            get: { model.autoCloseOnSourceClose },
            set: { model.setAutoCloseOnSourceClose($0) })
        )
        .accessibilityIdentifier("pip.settings.auto-close")

        Picker(
          L10n.string("settings.defaultFrameRate"),
          selection: Binding(
            get: { model.defaultFrameRate }, set: { model.setDefaultFrameRate($0) })
        ) {
          ForEach(FrameRate.allCases, id: \.self) { rate in
            Text(L10n.format("menu.frameRateValue", rate.framesPerSecond)).tag(rate)
          }
        }
        .accessibilityIdentifier("pip.settings.default-frame-rate")

        LabeledContent(L10n.string("settings.defaultOpacity")) {
          HStack {
            Slider(
              value: Binding(
                get: { model.defaultOpacity }, set: { model.setDefaultOpacity($0) }),
              in: AppSettings.opacityRange,
              step: 0.05
            )
            .labelsHidden()
            .accessibilityLabel(L10n.string("settings.defaultOpacity"))
            .accessibilityValue(Self.percentText(model.defaultOpacity))
            .accessibilityIdentifier("pip.settings.default-opacity")
            Text(Self.percentText(model.defaultOpacity))
              .monospacedDigit()
              .foregroundStyle(.secondary)
              .frame(minWidth: 40, alignment: .trailing)
              .accessibilityHidden(true)
          }
        }
      }

      Section(L10n.string("settings.section.shortcuts")) {
        Toggle(
          isOn: Binding(
            get: { model.clickThroughHotKeyEnabled },
            set: { model.setClickThroughHotKeyEnabled($0) })
        ) {
          HStack {
            Text(L10n.string("settings.clickThroughShortcut"))
            Spacer()
            Text("⌃⌥P")
              .foregroundStyle(.secondary)
              .accessibilityHidden(true)
          }
        }
        .accessibilityLabel(L10n.string("settings.clickThroughShortcut"))
        .accessibilityIdentifier("pip.settings.click-through-shortcut")
      }

      Section {
        VStack(spacing: 2) {
          Text(Self.appName)
            .font(.headline)
          if let version = Self.appVersion {
            Text(L10n.format("settings.version", version))
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("pip.settings.about")
      }
    }
    .formStyle(.grouped)
    .frame(width: 440)
    .fixedSize(horizontal: false, vertical: true)
  }

  private static func percentText(_ value: Double) -> String {
    (value).formatted(.percent.precision(.fractionLength(0)))
  }

  private static var appName: String {
    let info = Bundle.main.infoDictionary
    return (info?["CFBundleDisplayName"] as? String)
      ?? (info?["CFBundleName"] as? String)
      ?? ProcessInfo.processInfo.processName
  }

  private static var appVersion: String? {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
  }
}
