// Draws the app icon (a shipping label on a blue rounded square) and writes Resources/AppIcon.icns.
// Run with: make icon
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func color(_ hex: UInt32) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: 1
    )
}

/// Draws the icon on a 1024-point canvas, origin bottom-left.
func drawIcon(_ ctx: CGContext) {
    // Background: Apple's icon grid uses an 824pt rounded square centered on the 1024 canvas.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [color(0x4A8BF5), color(0x1F5FD6)] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    // The label: a 4x6 portrait card with a soft shadow.
    let label = CGRect(x: 512 - 200, y: 512 - 300, width: 400, height: 600)
    let labelPath = CGPath(roundedRect: label, cornerWidth: 28, cornerHeight: 28, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: CGColor(gray: 0, alpha: 0.3))
    ctx.addPath(labelPath)
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()

    let ink = color(0x1C1C1E)
    let inset = label.insetBy(dx: 44, dy: 44)

    // Header bar and a few "address" lines.
    ctx.setFillColor(ink)
    ctx.fill(CGRect(x: inset.minX, y: inset.maxY - 70, width: inset.width, height: 70))
    ctx.setFillColor(color(0x8E8E93))
    let lineWidths: [CGFloat] = [0.75, 0.55, 0.65]
    for (i, fraction) in lineWidths.enumerated() {
        let y = inset.maxY - 120 - CGFloat(i) * 46
        ctx.fill(CGRect(x: inset.minX, y: y - 22, width: inset.width * fraction, height: 22))
    }

    // Barcode.
    ctx.setFillColor(ink)
    let bars: [CGFloat] = [3, 1, 2, 1, 3, 2, 1, 1, 3, 1, 2, 3, 1, 2, 1, 3, 1, 2, 2, 1, 3, 1]
    let unit = inset.width / bars.reduce(0) { $0 + $1 + 1 }
    var x = inset.minX
    for bar in bars {
        ctx.fill(CGRect(x: x, y: inset.minY, width: bar * unit, height: 170))
        x += (bar + 1) * unit
    }
}

func png(size: Int) -> Data {
    let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    drawIcon(ctx)

    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    return data as Data
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
    try png(size: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try png(size: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let output = root.appendingPathComponent("Resources/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(output.path)")
