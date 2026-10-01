import AppKit
import CoreGraphics

/// Screen Recording (TCC) permission helpers.
enum ScreenCapturePermission {
  /// Whether Screen Recording access is currently granted. Does not prompt.
  static var isGranted: Bool {
    CGPreflightScreenCaptureAccess()
  }

  /// Requests Screen Recording access, prompting the first time only. Returns
  /// whether access is granted now; a fresh grant usually needs an app relaunch
  /// before capture works.
  @discardableResult
  static func request() -> Bool {
    CGRequestScreenCaptureAccess()
  }

  /// Opens System Settings › Privacy & Security › Screen Recording.
  @MainActor
  static func openSystemSettings() {
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
      )
    else { return }
    NSWorkspace.shared.open(url)
  }
}
