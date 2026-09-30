// Renders the app icon and packs it into an .icns file.
// Usage: swift scripts/make-icon.swift Resources/AppIcon.icns
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
  FileHandle.standardError.write(Data("usage: make-icon.swift <output.icns>\n".utf8))
  exit(2)
}

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("error: \(message)\n".utf8))
  exit(1)
}

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
  CGColor(
    red: CGFloat((hex >> 16) & 0xFF) / 255,
    green: CGFloat((hex >> 8) & 0xFF) / 255,
    blue: CGFloat(hex & 0xFF) / 255,
    alpha: alpha
  )
}

func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
  CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// Draws the icon on a 1024-unit canvas scaled to `side` pixels.
func renderPNG(side: Int) -> Data {
  guard
    let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: side,
      pixelsHigh: side,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    ),
    let graphics = NSGraphicsContext(bitmapImageRep: bitmap)
  else { fail("cannot create \(side)px bitmap context") }

  let context = graphics.cgContext
  let space = CGColorSpaceCreateDeviceRGB()
  let scale = CGFloat(side) / 1024
  context.scaleBy(x: scale, y: scale)

  func fillGradient(_ path: CGPath, _ colors: [CGColor], from start: CGPoint, to end: CGPoint) {
    context.saveGState()
    context.addPath(path)
    context.clip()
    let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
    context.drawLinearGradient(gradient, start: start, end: end, options: [])
    context.restoreGState()
  }

  // Shadow offsets and blur are in device space, so scale them explicitly.
  func setShadow(y: CGFloat, blur: CGFloat, alpha: CGFloat) {
    context.setShadow(
      offset: CGSize(width: 0, height: y * scale),
      blur: blur * scale,
      color: color(0x000000, alpha: alpha)
    )
  }

  // macOS icon grid: 824-unit body centred on the 1024-unit canvas.
  let body = CGRect(x: 100, y: 100, width: 824, height: 824)
  let bodyPath = roundedRect(body, radius: 185)
  context.saveGState()
  setShadow(y: -12, blur: 28, alpha: 0.35)
  context.addPath(bodyPath)
  context.setFillColor(color(0x1B2A4A))
  context.fillPath()
  context.restoreGState()
  fillGradient(
    bodyPath,
    [color(0x3A7BFF), color(0x2340B8)],
    from: CGPoint(x: body.midX, y: body.maxY),
    to: CGPoint(x: body.midX, y: body.minY)
  )

  // Source window.
  let screen = CGRect(x: 200, y: 262, width: 624, height: 500)
  let screenPath = roundedRect(screen, radius: 56)
  context.saveGState()
  setShadow(y: -8, blur: 20, alpha: 0.25)
  context.addPath(screenPath)
  context.setFillColor(color(0xEAF1FF))
  context.fillPath()
  context.restoreGState()

  context.saveGState()
  context.addPath(screenPath)
  context.clip()
  context.setFillColor(color(0xC9D7F5))
  context.fill(CGRect(x: screen.minX, y: screen.maxY - 76, width: screen.width, height: 76))
  context.restoreGState()
  for (index, hex) in [UInt32(0xFF5F57), 0xFEBC2E, 0x28C840].enumerated() {
    let center = CGPoint(x: screen.minX + 52 + CGFloat(index) * 44, y: screen.maxY - 38)
    context.setFillColor(color(hex))
    context.fillEllipse(in: CGRect(x: center.x - 14, y: center.y - 14, width: 28, height: 28))
  }

  // Floating picture-in-picture window over the bottom-right corner.
  let pip = CGRect(x: 520, y: 180, width: 360, height: 250)
  let pipPath = roundedRect(pip, radius: 40)
  context.saveGState()
  setShadow(y: -14, blur: 34, alpha: 0.45)
  context.addPath(pipPath)
  context.setFillColor(color(0x10182B))
  context.fillPath()
  context.restoreGState()
  fillGradient(
    pipPath,
    [color(0x1F2C4D), color(0x0C1222)],
    from: CGPoint(x: pip.midX, y: pip.maxY),
    to: CGPoint(x: pip.midX, y: pip.minY)
  )
  context.addPath(pipPath)
  context.setStrokeColor(color(0xFFFFFF, alpha: 0.9))
  context.setLineWidth(10)
  context.strokePath()

  let play = CGMutablePath()
  play.move(to: CGPoint(x: pip.midX - 38, y: pip.midY + 52))
  play.addLine(to: CGPoint(x: pip.midX - 38, y: pip.midY - 52))
  play.addLine(to: CGPoint(x: pip.midX + 56, y: pip.midY))
  play.closeSubpath()
  context.addPath(play)
  context.setFillColor(color(0xFFFFFF))
  context.fillPath()

  graphics.flushGraphics()
  guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fail("cannot encode \(side)px PNG")
  }
  return png
}

let fileManager = FileManager.default
let iconset = fileManager.temporaryDirectory
  .appendingPathComponent(UUID().uuidString)
  .appendingPathComponent("AppIcon.iconset")
defer { try? fileManager.removeItem(at: iconset.deletingLastPathComponent()) }

do {
  try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
  for points in [16, 32, 128, 256, 512] {
    try renderPNG(side: points).write(
      to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try renderPNG(side: points * 2).write(
      to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
  }
} catch {
  fail(error.localizedDescription)
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["--convert", "icns", "--output", arguments[1], iconset.path]
do {
  try iconutil.run()
} catch {
  fail("cannot run iconutil: \(error.localizedDescription)")
}
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
  fail("iconutil exited with status \(iconutil.terminationStatus)")
}
