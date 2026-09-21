import Foundation

enum CaptureState: Equatable {
  case idle
  case selecting
  case starting
  case running(String)
  case suspended(String)
  case stopped(String)
  case failed(String)
}
