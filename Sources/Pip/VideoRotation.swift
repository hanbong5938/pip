import CoreGraphics

/// Clockwise display rotation applied to the mirrored video. The raw value is
/// the number of clockwise quarter turns and is passed to Video.metal as-is.
enum VideoRotation: Int, Sendable {
  case none = 0
  case clockwise90 = 1
  case upsideDown = 2
  case clockwise270 = 3

  /// The rotation one further quarter turn clockwise, wrapping after 270°.
  var next: VideoRotation {
    VideoRotation(rawValue: (rawValue + 1) % 4) ?? .none
  }

  /// Quarter turns exchange the displayed width and height.
  var swapsDimensions: Bool {
    rawValue % 2 == 1
  }

  var degrees: Int {
    rawValue * 90
  }

  /// Maps a rect normalized to the displayed (rotated) video onto the same
  /// pixels in source orientation. Both rects are unit-normalized with a
  /// top-left origin.
  ///
  /// Mirrors the vertex remap in Video.metal, where the displayed point
  /// `(u, v)` shows source point `(v, 1 − u)` at 90°, `(1 − u, 1 − v)` at 180°
  /// and `(1 − v, u)` at 270°. Keep the two in lockstep.
  func sourceRect(fromDisplayRect rect: CGRect) -> CGRect {
    let r = rect.standardized
    switch self {
    case .none:
      return r
    case .clockwise90:
      return CGRect(x: r.minY, y: 1 - r.maxX, width: r.height, height: r.width)
    case .upsideDown:
      return CGRect(x: 1 - r.maxX, y: 1 - r.maxY, width: r.width, height: r.height)
    case .clockwise270:
      return CGRect(x: 1 - r.maxY, y: r.minX, width: r.height, height: r.width)
    }
  }
}
