import Foundation

/// Capture frame rates offered to the user. Raw values are frames per second and
/// are what gets persisted, so existing cases must never be renumbered.
enum FrameRate: Int, CaseIterable, Sendable {
  case fps1 = 1
  case fps5 = 5
  case fps15 = 15
  case fps30 = 30
  case fps60 = 60

  var framesPerSecond: Int { rawValue }
}

/// Typed, UserDefaults-backed app preferences.
///
/// Reads always go to `defaults` so external writes (e.g. `defaults write`) are
/// observed. Setters only persist and fire `onChange` when the effective value
/// actually changes.
@MainActor
final class AppSettings {
  static let opacityRange: ClosedRange<Double> = 0.2...1.0

  /// Called after any setter changes a stored value.
  var onChange: (() -> Void)?

  private enum Key {
    static let autoCloseOnSourceClose = "autoCloseOnSourceClose"
    static let defaultFrameRate = "defaultFrameRate"
    static let defaultOpacity = "defaultOpacity"
    static let clickThroughHotKeyEnabled = "clickThroughHotKeyEnabled"
  }

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// Close the PiP panel when the captured source window goes away. Default `false`.
  var autoCloseOnSourceClose: Bool {
    get { bool(Key.autoCloseOnSourceClose, default: false) }
    set { setBool(newValue, for: Key.autoCloseOnSourceClose, current: autoCloseOnSourceClose) }
  }

  /// Frame rate applied to newly started captures. Unknown stored values fall
  /// back to `.fps30`.
  var defaultFrameRate: FrameRate {
    get {
      guard defaults.object(forKey: Key.defaultFrameRate) != nil,
        let rate = FrameRate(rawValue: defaults.integer(forKey: Key.defaultFrameRate))
      else { return .fps30 }
      return rate
    }
    set {
      guard newValue != defaultFrameRate else { return }
      defaults.set(newValue.rawValue, forKey: Key.defaultFrameRate)
      onChange?()
    }
  }

  /// Panel opacity applied to new PiP windows, always within `opacityRange`.
  /// Default `1.0`.
  var defaultOpacity: Double {
    get {
      guard defaults.object(forKey: Key.defaultOpacity) != nil else { return 1.0 }
      return Self.clampOpacity(defaults.double(forKey: Key.defaultOpacity))
    }
    set {
      let clamped = Self.clampOpacity(newValue)
      guard clamped != defaultOpacity else { return }
      defaults.set(clamped, forKey: Key.defaultOpacity)
      onChange?()
    }
  }

  /// Whether the global click-through hot key (⌃⌥P) is registered. Default `true`.
  var clickThroughHotKeyEnabled: Bool {
    get { bool(Key.clickThroughHotKeyEnabled, default: true) }
    set {
      setBool(newValue, for: Key.clickThroughHotKeyEnabled, current: clickThroughHotKeyEnabled)
    }
  }

  private func bool(_ key: String, default defaultValue: Bool) -> Bool {
    guard defaults.object(forKey: key) != nil else { return defaultValue }
    return defaults.bool(forKey: key)
  }

  private func setBool(_ value: Bool, for key: String, current: Bool) {
    guard value != current else { return }
    defaults.set(value, forKey: key)
    onChange?()
  }

  /// Clamps to `opacityRange`; non-finite input maps to fully opaque.
  private static func clampOpacity(_ value: Double) -> Double {
    guard value.isFinite else { return opacityRange.upperBound }
    return min(max(value, opacityRange.lowerBound), opacityRange.upperBound)
  }
}
