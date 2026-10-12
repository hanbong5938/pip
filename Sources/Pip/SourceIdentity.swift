import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// A snapshot of the single window accepted for capture. The window number is
/// only meaningful together with its owning process and application launch.
struct SourceIdentity: Equatable, Sendable {
  let windowID: CGWindowID
  let processID: pid_t
  let bundleIdentifier: String?
  let appName: String
  let title: String
  let launchDate: Date?
  let sourceSize: CGSize

  @MainActor
  static func from(filter: SCContentFilter) -> SourceIdentity? {
    guard filter.style == .window,
      filter.includedWindows.count == 1,
      let window = filter.includedWindows.first,
      let app = window.owningApplication
    else { return nil }

    let bundleIdentifier = app.bundleIdentifier.isEmpty ? nil : app.bundleIdentifier
    return SourceIdentity(
      windowID: window.windowID,
      processID: app.processID,
      bundleIdentifier: bundleIdentifier,
      appName: app.applicationName,
      title: window.title ?? "",
      launchDate: NSRunningApplication(processIdentifier: app.processID)?.launchDate,
      sourceSize: window.frame.size
    )
  }

  @MainActor
  func isSameRunningApplication() -> Bool {
    guard processID > 0, let launchDate,
      let application = NSRunningApplication(processIdentifier: processID),
      !application.isTerminated,
      application.processIdentifier == processID,
      application.launchDate == launchDate
    else { return false }
    return application.bundleIdentifier == bundleIdentifier
  }
}

enum SelectionIssue: Equatable, Sendable {
  case catalogUnavailable
  case sourceUnavailable
  case selectionUnavailable
  case pickerUnavailable
  case pickerBusy
  case sourceAppUnavailable
  case setupUnavailable

  var messageKey: String {
    switch self {
    case .catalogUnavailable: "selectionIssue.catalogUnavailable"
    case .sourceUnavailable: "selectionIssue.sourceUnavailable"
    case .selectionUnavailable: "selectionIssue.selectionUnavailable"
    case .pickerUnavailable: "selectionIssue.pickerUnavailable"
    case .pickerBusy: "selectionIssue.pickerBusy"
    case .sourceAppUnavailable: "selectionIssue.sourceAppUnavailable"
    case .setupUnavailable: "selectionIssue.setupUnavailable"
    }
  }
}
