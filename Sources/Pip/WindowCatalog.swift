import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Sendable snapshot of a capturable window. `SCWindow` itself never leaves
/// `WindowCatalog`; callers identify windows by `id` and resolve them again via
/// `WindowCatalog.makeFilter(for:)`.
struct CapturableWindow: Identifiable, Hashable, Sendable {
  let id: CGWindowID
  let appName: String
  let bundleIdentifier: String?
  let title: String
  let processID: pid_t

  var displayTitle: String { title.isEmpty ? appName : title }
}

enum WindowCatalogError: Error {
  /// Screen Recording permission is missing or was declined.
  case permissionDenied
  /// The requested window no longer exists or is no longer shareable.
  case windowNotFound
  /// ScreenCaptureKit failed for another reason; payload is a diagnostic
  /// description, not meant to be shown verbatim.
  case unavailable(String)
}

/// In-app window list backed by `SCShareableContent`, complementing the system
/// `SCContentSharingPicker`.
@MainActor
enum WindowCatalog {
  /// Smallest width/height for a window to be listed; filters out helper and
  /// tooltip-sized windows.
  private static let minimumSize: CGFloat = 64

  /// System UI owners that are never useful PiP sources.
  private static let excludedBundleIdentifiers: Set<String> = [
    "com.apple.controlcenter",
    "com.apple.notificationcenterui",
    "com.apple.WindowManager",
    "com.apple.screencaptureui",
    "com.apple.dock",
  ]

  /// On-screen, normal-layer windows of other apps, sorted by app name then
  /// title.
  static func fetch() async throws -> [CapturableWindow] {
    let content = try await shareableContent(onScreenWindowsOnly: true)
    let ownBundleIdentifier = Bundle.main.bundleIdentifier

    return content.windows
      .filter { window in
        guard window.windowLayer == 0,
          window.frame.width >= minimumSize,
          window.frame.height >= minimumSize,
          let app = window.owningApplication
        else { return false }
        let bundleIdentifier = app.bundleIdentifier
        if let ownBundleIdentifier, bundleIdentifier == ownBundleIdentifier { return false }
        return !excludedBundleIdentifiers.contains(bundleIdentifier)
      }
      .compactMap(capturableWindow(from:))
      .sorted { lhs, rhs in
        switch lhs.appName.localizedStandardCompare(rhs.appName) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame:
          return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
      }
  }

  /// Resolves `windowID` against fresh shareable content and builds a
  /// single-window filter. Off-screen windows are included in the lookup so a
  /// window that was listed moments ago still resolves while briefly hidden.
  static func makeFilter(
    for windowID: CGWindowID
  ) async throws -> (filter: SCContentFilter, window: CapturableWindow) {
    let content = try await shareableContent(onScreenWindowsOnly: false)
    guard let scWindow = content.windows.first(where: { $0.windowID == windowID }),
      let window = capturableWindow(from: scWindow)
    else { throw WindowCatalogError.windowNotFound }
    return (SCContentFilter(desktopIndependentWindow: scWindow), window)
  }

  /// Cheap liveness check via the window server. Needs no Screen Recording
  /// permission because only the window number is inspected.
  static func windowExists(_ windowID: CGWindowID) -> Bool {
    guard
      let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID)
        as? [[String: Any]]
    else { return false }
    return info.contains { entry in
      (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID
    }
  }

  private static func shareableContent(
    onScreenWindowsOnly: Bool
  ) async throws -> SCShareableContent {
    do {
      return try await SCShareableContent.excludingDesktopWindows(
        true,
        onScreenWindowsOnly: onScreenWindowsOnly
      )
    } catch {
      throw mapError(error)
    }
  }

  /// ScreenCaptureKit reports missing TCC consent as `userDeclined` or as
  /// assorted TCC errors; whenever preflight says access is not granted the
  /// failure is treated as a permission problem.
  private static func mapError(_ error: any Error) -> WindowCatalogError {
    if let error = error as? WindowCatalogError { return error }
    let nsError = error as NSError
    let isUserDeclined =
      nsError.domain == SCStreamErrorDomain
      && nsError.code == SCStreamError.Code.userDeclined.rawValue
    if !ScreenCapturePermission.isGranted || isUserDeclined {
      return .permissionDenied
    }
    return .unavailable(String(describing: error))
  }

  private static func capturableWindow(from window: SCWindow) -> CapturableWindow? {
    guard let app = window.owningApplication else { return nil }
    let bundleIdentifier = app.bundleIdentifier
    return CapturableWindow(
      id: window.windowID,
      appName: app.applicationName,
      bundleIdentifier: bundleIdentifier.isEmpty ? nil : bundleIdentifier,
      title: window.title ?? "",
      processID: app.processID
    )
  }
}
