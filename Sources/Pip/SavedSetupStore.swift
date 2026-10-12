import CoreGraphics
import Foundation

/// A local recipe, not a source identity or permission to start capture.
/// Restoring it requires a fresh, explicit source selection and confirmation.
struct SavedSetup: Codable, Equatable {
  struct NormalizedCrop: Codable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ rect: CGRect) {
      x = Double(rect.origin.x)
      y = Double(rect.origin.y)
      width = Double(rect.width)
      height = Double(rect.height)
    }

    var rect: CGRect {
      CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(width), height: CGFloat(height))
    }

    var isValid: Bool {
      x.isFinite && y.isFinite && width.isFinite && height.isFinite
        && x >= 0 && y >= 0 && width >= 0.01 && height >= 0.01
        && x + width <= 1 && y + height <= 1
    }
  }

  let appBundleIdentifier: String?
  let appName: String
  private let normalizedCrop: NormalizedCrop?
  let sourceWidth: Double
  let sourceHeight: Double
  let frameRate: Int
  let opacity: Double
  let rotationDegrees: Int

  var crop: CGRect? { normalizedCrop?.rect }
  var sourceSize: CGSize { CGSize(width: CGFloat(sourceWidth), height: CGFloat(sourceHeight)) }

  var isValid: Bool {
    sourceWidth.isFinite && sourceHeight.isFinite
      && sourceWidth > 0 && sourceHeight > 0
      && (normalizedCrop?.isValid ?? true)
      && FrameRate(rawValue: frameRate) != nil
      && opacity.isFinite && (0.2...1.0).contains(opacity)
      && (rotationDegrees == 0 || rotationDegrees == 90
        || rotationDegrees == 180 || rotationDegrees == 270)
  }

  init?(
    appBundleIdentifier: String?,
    appName: String,
    crop: CGRect?,
    sourceSize: CGSize,
    frameRate: Int,
    opacity: Double,
    rotationDegrees: Int
  ) {
    self.appBundleIdentifier = appBundleIdentifier
    self.appName = appName
    normalizedCrop = crop.map(NormalizedCrop.init)
    sourceWidth = Double(sourceSize.width)
    sourceHeight = Double(sourceSize.height)
    self.frameRate = frameRate
    self.opacity = opacity
    self.rotationDegrees = rotationDegrees
    guard isValid else { return nil }
  }
}

/// One explicitly saved recipe; reads consult UserDefaults so external changes
/// and isolated test suites are observed without caching stale data.
@MainActor
final class SavedSetupStore {
  private static let key = "pip.savedSetup"

  var onChange: (() -> Void)?

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  var savedSetup: SavedSetup? {
    guard let data = defaults.data(forKey: Self.key),
      let setup = try? JSONDecoder().decode(SavedSetup.self, from: data),
      setup.isValid
    else { return nil }
    return setup
  }

  @discardableResult
  func save(_ setup: SavedSetup) -> Bool {
    guard setup.isValid, let data = try? JSONEncoder().encode(setup) else { return false }
    guard savedSetup != setup else { return true }
    defaults.set(data, forKey: Self.key)
    onChange?()
    return true
  }

  func delete() {
    let hadSavedSetup = savedSetup != nil
    defaults.removeObject(forKey: Self.key)
    if hadSavedSetup { onChange?() }
  }
}
