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
}
