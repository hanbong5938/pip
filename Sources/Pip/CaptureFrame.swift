import CoreVideo
import Foundation

struct CaptureFrame: @unchecked Sendable {
  let pixelBuffer: CVPixelBuffer
  let contentRect: CGRect
  let displayTime: UInt64?
  let generation: UInt64
}
