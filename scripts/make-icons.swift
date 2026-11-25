// Generates the web app icons (PNG) with CoreGraphics: `swift scripts/make-icons.swift`
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "web/static/icons")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

/// Draws the icon: warm gradient tile, white rounded photo frame with sun and mountains.
/// `safe` shrinks the artwork for maskable icons (80% safe zone).
func icon(size: Int, rounded: Bool, safe: CGFloat = 1) -> CGImage {
    let s = CGFloat(size)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let tile = CGRect(x: 0, y: 0, width: s, height: s)
    if rounded {
        ctx.addPath(CGPath(roundedRect: tile, cornerWidth: s * 0.225, cornerHeight: s * 0.225, transform: nil))
        ctx.clip()
    }
    let gradient = CGGradient(colorsSpace: cs, colors: [
        CGColor(red: 1.00, green: 0.62, blue: 0.24, alpha: 1),
        CGColor(red: 0.96, green: 0.27, blue: 0.47, alpha: 1),
        CGColor(red: 0.45, green: 0.30, blue: 0.95, alpha: 1),
    ] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])

    let inset = s * (1 - 0.62 * safe) / 2
    let frame = tile.insetBy(dx: inset, dy: inset + s * 0.05 * safe)
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
    ctx.addPath(CGPath(roundedRect: frame, cornerWidth: s * 0.06 * safe, cornerHeight: s * 0.06 * safe, transform: nil))
    ctx.fillPath()

    // sun
    let sun = s * 0.065 * safe
    ctx.setFillColor(CGColor(red: 1.00, green: 0.62, blue: 0.24, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: frame.maxX - frame.width * 0.32 - sun, y: frame.maxY - frame.height * 0.30 - sun, width: sun * 2, height: sun * 2))
    // mountains
    ctx.setFillColor(CGColor(red: 0.45, green: 0.30, blue: 0.95, alpha: 1))
    let b = frame.minY + frame.height * 0.14
    ctx.move(to: CGPoint(x: frame.minX + frame.width * 0.10, y: b))
    ctx.addLine(to: CGPoint(x: frame.minX + frame.width * 0.40, y: frame.minY + frame.height * 0.62))
    ctx.addLine(to: CGPoint(x: frame.minX + frame.width * 0.62, y: b))
    ctx.closePath()
    ctx.fillPath()
    ctx.setFillColor(CGColor(red: 0.96, green: 0.27, blue: 0.47, alpha: 1))
    ctx.move(to: CGPoint(x: frame.minX + frame.width * 0.42, y: b))
    ctx.addLine(to: CGPoint(x: frame.minX + frame.width * 0.66, y: frame.minY + frame.height * 0.46))
    ctx.addLine(to: CGPoint(x: frame.minX + frame.width * 0.90, y: b))
    ctx.closePath()
    ctx.fillPath()
    return ctx.makeImage()!
}

func write(_ img: CGImage, _ name: String) {
    let url = out.appendingPathComponent(name)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
    print("wrote \(url.path)")
}

write(icon(size: 192, rounded: false), "icon-192.png")
write(icon(size: 512, rounded: false), "icon-512.png")
write(icon(size: 512, rounded: false, safe: 0.8), "maskable-512.png")
write(icon(size: 180, rounded: false), "apple-touch-icon.png")  // iOS rounds the corners itself
write(icon(size: 64, rounded: true), "favicon-64.png")
