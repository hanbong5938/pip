import AppKit

@main
@MainActor
struct Main {
  static func main() {
    let application = NSApplication.shared
    let delegate = AppController()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) {
      application.run()
    }
  }
}
