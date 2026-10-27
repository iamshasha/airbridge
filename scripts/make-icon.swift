// Renders the AirBridge app icon (1024×1024 PNG): blue gradient with two crossing arrows.
// Usage: swift scripts/make-icon.swift <output.png> [--mac]
// --mac draws the macOS shape: a rounded square inset on a transparent canvas (iOS masks icons itself).
import AppKit

let mac = CommandLine.arguments.contains("--mac")
let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
if mac {
    let inset = 100.0
    ctx.addPath(CGPath(roundedRect: CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset),
                       cornerWidth: 185, cornerHeight: 185, transform: nil))
    ctx.clip()
}
let colors = [NSColor(srgbRed: 0.10, green: 0.48, blue: 1.0, alpha: 1).cgColor,
              NSColor(srgbRed: 0.18, green: 0.82, blue: 0.95, alpha: 1).cgColor] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])

// Soft highlight so the flat gradient has some depth.
let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                      colors: [NSColor(white: 1, alpha: 0.28).cgColor, NSColor(white: 1, alpha: 0).cgColor] as CFArray,
                      locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: size * 0.3, y: size * 0.8), startRadius: 0,
                       endCenter: CGPoint(x: size * 0.3, y: size * 0.8), endRadius: size * 0.7, options: [])

let config = NSImage.SymbolConfiguration(pointSize: mac ? 420 : 520, weight: .semibold)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
let symbol = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
let s = symbol.size
symbol.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2, width: s.width, height: s.height))
image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
// Flatten to exactly 1024×1024 pixels regardless of screen scale.
let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
rep.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024))
NSGraphicsContext.restoreGraphicsState()
try! out.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
