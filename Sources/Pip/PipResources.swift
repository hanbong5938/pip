import Foundation

/// The SwiftPM resource bundle (shader and string tables), located without
/// `Bundle.module`: depending on the build system, its generated accessor
/// misses a bundle inside `Contents/Resources` and calls `fatalError`.
enum PipResources {
  /// `nil` when the bundle is missing; callers degrade instead of crashing.
  static let bundle: Bundle? = {
    let name = "Pip_Pip.bundle"
    // Pip.app/Contents/Resources (build-app.sh), then next to the binary (swift run).
    for base in [Bundle.main.resourceURL, Bundle.main.bundleURL] {
      guard let url = base?.appendingPathComponent(name),
        FileManager.default.fileExists(atPath: url.path),
        let bundle = Bundle(url: url)
      else { continue }
      return bundle
    }
    return nil
  }()
}
