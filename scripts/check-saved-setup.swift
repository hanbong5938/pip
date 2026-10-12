import CoreGraphics
import Foundation

@main
@MainActor
struct SavedSetupChecks {
  private static let key = "pip.savedSetup"

  private struct Failure: Error, CustomStringConvertible {
    let description: String
  }

  private static func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
    guard condition() else { throw Failure(description: label) }
  }

  private static func require<T>(_ value: T?, _ label: String) throws -> T {
    guard let value else { throw Failure(description: label) }
    return value
  }

  private static func withStore(_ body: (UserDefaults, SavedSetupStore) throws -> Void) throws {
    let suite = "Pip.SavedSetupChecks.\(UUID().uuidString)"
    let defaults = try require(UserDefaults(suiteName: suite), "create isolated defaults suite")
    defaults.removePersistentDomain(forName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    try body(defaults, SavedSetupStore(defaults: defaults))
  }

  private static func recipe(
    crop: CGRect? = CGRect(x: 0.125, y: 0.25, width: 0.625, height: 0.5),
    sourceSize: CGSize = CGSize(width: 2048, height: 1152),
    frameRate: Int = 15,
    opacity: Double = 0.73,
    rotationDegrees: Int = 270
  ) -> SavedSetup? {
    SavedSetup(
      appBundleIdentifier: "org.example.editor",
      appName: "Editor",
      crop: crop,
      sourceSize: sourceSize,
      frameRate: frameRate,
      opacity: opacity,
      rotationDegrees: rotationDegrees
    )
  }

  private static func modifiedData(
    from setup: SavedSetup,
    _ change: (inout [String: Any]) throws -> Void
  ) throws -> Data {
    let encoded = try JSONEncoder().encode(setup)
    var object = try require(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any], "decode recipe JSON object")
    try change(&object)
    return try JSONSerialization.data(withJSONObject: object)
  }

  private static func run() throws {
    try withStore { defaults, store in
      let setup = try require(recipe(), "construct valid recipe")
      try check(store.savedSetup == nil, "opt-in: no saved recipe before save")
      try check(
        defaults.object(forKey: key) == nil, "opt-in: constructing recipe does not write defaults")
      try check(
        SavedSetupStore(defaults: defaults).savedSetup == nil, "opt-in: fresh store sees no recipe")

      try check(store.save(setup), "explicit save succeeds")
      try check(defaults.data(forKey: key) != nil, "explicit save writes data")
      let reopened = SavedSetupStore(defaults: defaults)
      try check(reopened.savedSetup == setup, "reopened store preserves exact recipe")
      try check(
        reopened.savedSetup?.appBundleIdentifier == "org.example.editor",
        "persisted bundle identifier")
      try check(reopened.savedSetup?.appName == "Editor", "persisted app name")
      try check(
        reopened.savedSetup?.crop == CGRect(x: 0.125, y: 0.25, width: 0.625, height: 0.5),
        "persisted crop")
      try check(
        reopened.savedSetup?.sourceSize == CGSize(width: 2048, height: 1152),
        "persisted source size")
      try check(reopened.savedSetup?.frameRate == 15, "persisted frame rate")
      try check(reopened.savedSetup?.opacity == 0.73, "persisted opacity")
      try check(reopened.savedSetup?.rotationDegrees == 270, "persisted rotation")

      let invalidData = try modifiedData(from: setup) { $0["frameRate"] = 24 }
      let invalid = try JSONDecoder().decode(SavedSetup.self, from: invalidData)
      try check(!invalid.isValid, "decoded invalid recipe is rejected by validation")
      try check(!store.save(invalid), "invalid save fails")
      try check(
        SavedSetupStore(defaults: defaults).savedSetup == setup,
        "invalid save preserves good recipe")

      store.delete()
      try check(defaults.object(forKey: key) == nil, "forget removes stored data")
      try check(
        SavedSetupStore(defaults: defaults).savedSetup == nil, "forget visible to fresh store")
    }

    try withStore { defaults, store in
      defaults.set(Data("not JSON".utf8), forKey: key)
      try check(store.savedSetup == nil, "corrupt stored JSON rejected")

      let setup = try require(recipe(), "construct recipe for corrupt payload checks")
      defaults.set(try modifiedData(from: setup) { $0["sourceWidth"] = -1.0 }, forKey: key)
      try check(store.savedSetup == nil, "invalid stored dimension rejected")

      let invalidCrop = try modifiedData(from: setup) { object in
        var crop = try require(
          object["normalizedCrop"] as? [String: Any], "decode normalized crop JSON")
        crop["width"] = 1.0
        object["normalizedCrop"] = crop
      }
      defaults.set(invalidCrop, forKey: key)
      try check(
        SavedSetupStore(defaults: defaults).savedSetup == nil,
        "invalid stored crop rejected by fresh store")
    }

    try check(
      recipe(crop: CGRect(x: 0, y: 0, width: 0.01, height: 0.01)) != nil, "minimum crop accepted")
    try check(
      recipe(crop: CGRect(x: 0.25, y: 0.5, width: 0.75, height: 0.5)) != nil,
      "crop on exact far edges accepted")
    try check(
      recipe(crop: CGRect(x: -0.01, y: 0, width: 0.5, height: 0.5)) == nil,
      "negative crop x rejected")
    try check(
      recipe(crop: CGRect(x: 0, y: -0.01, width: 0.5, height: 0.5)) == nil,
      "negative crop y rejected")
    try check(
      recipe(crop: CGRect(x: 0.5, y: 0, width: 0.51, height: 0.5)) == nil,
      "crop overflow x rejected")
    try check(
      recipe(crop: CGRect(x: 0, y: 0.5, width: 0.5, height: 0.51)) == nil,
      "crop overflow y rejected")
    try check(
      recipe(crop: CGRect(x: 0, y: 0, width: 0.009, height: 0.5)) == nil,
      "crop below minimum width rejected")
    try check(
      recipe(crop: CGRect(x: 0, y: 0, width: 0.5, height: 0.009)) == nil,
      "crop below minimum height rejected")
    try check(
      recipe(crop: CGRect(x: CGFloat.nan, y: 0, width: 0.5, height: 0.5)) == nil,
      "nonfinite crop rejected"
    )

    try check(recipe(frameRate: 24) == nil, "unsupported frame rate rejected")
    try check(recipe(rotationDegrees: 45) == nil, "unsupported rotation rejected")
    try check(recipe(opacity: .nan) == nil, "NaN opacity rejected")
    try check(recipe(opacity: .infinity) == nil, "infinite opacity rejected")
    try check(recipe(opacity: 0.19) == nil, "opacity below range rejected")
    try check(recipe(opacity: 1.01) == nil, "opacity above range rejected")
    try check(recipe(sourceSize: CGSize(width: 0, height: 1152)) == nil, "zero width rejected")
    try check(
      recipe(sourceSize: CGSize(width: 2048, height: -1)) == nil, "negative height rejected")
    try check(
      recipe(sourceSize: CGSize(width: CGFloat.infinity, height: 1152)) == nil,
      "infinite width rejected")
    try check(
      recipe(sourceSize: CGSize(width: 2048, height: CGFloat.nan)) == nil, "NaN height rejected")
  }

  static func main() {
    do {
      try run()
      print("SavedSetupStore regression checks passed")
    } catch {
      FileHandle.standardError.write(
        Data("SavedSetupStore regression checks failed: \(error)\n".utf8))
      exit(1)
    }
  }
}
