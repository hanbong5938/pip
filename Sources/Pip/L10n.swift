import Foundation

/// Looks up user-facing strings in the SwiftPM resource bundle's `Localizable.strings` tables,
/// returning the key itself when the bundle is missing.
///
/// English (`en.lproj`) is the development language; every key must also exist in `ko.lproj`
/// so the two tables stay in lockstep. Keys are dotted lowercase camel (`panel.close`).
enum L10n {
  static func string(_ key: String) -> String {
    guard let bundle = PipResources.bundle else { return key }
    return NSLocalizedString(key, bundle: bundle, comment: "")
  }

  /// Formats a localized template (`%@`, `%d`) using the user's current locale.
  static func format(_ key: String, _ args: CVarArg...) -> String {
    String(format: string(key), locale: .current, arguments: args)
  }
}
