import Foundation
import ServiceManagement

/// Launch-at-login control backed by `SMAppService.mainApp`.
///
/// Status is always read live from the service; the system (and the user via
/// System Settings › Login Items) is the source of truth, so nothing is cached.
@MainActor
enum LoginItem {
  /// `true` when the app is registered and approved to launch at login.
  static var isEnabled: Bool {
    SMAppService.mainApp.status == .enabled
  }

  /// `true` when registered but the user still has to approve it in
  /// System Settings › Login Items.
  static var requiresApproval: Bool {
    SMAppService.mainApp.status == .requiresApproval
  }

  /// Registers or unregisters the main app as a login item. No-op when the
  /// current status already matches the request. Errors come straight from
  /// `SMAppService`; callers present them.
  static func setEnabled(_ enabled: Bool) throws {
    let service = SMAppService.mainApp
    if enabled {
      guard service.status != .enabled, service.status != .requiresApproval else { return }
      try service.register()
    } else {
      guard service.status == .enabled || service.status == .requiresApproval else { return }
      try service.unregister()
    }
  }

  static func openLoginItemsSettings() {
    SMAppService.openSystemSettingsLoginItems()
  }
}
