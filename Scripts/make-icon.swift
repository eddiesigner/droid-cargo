// Renders the placeholder app icon: usage `swift Scripts/make-icon.swift <out.png>`
import AppKit

let canvas: CGFloat = 1024
let inset: CGFloat = 100
let output = CommandLine.arguments[1]

let image = NSImage(size: NSSize(width: canvas, height: canvas), flipped: false) { _ in
    // macOS icon grid: 824pt body with continuous corners and a soft drop shadow.
    let body = NSRect(x: inset, y: inset + 10, width: canvas - inset * 2, height: canvas - inset * 2)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.33, green: 0.86, blue: 0.56, alpha: 1),
        NSColor(srgbRed: 0.06, green: 0.52, blue: 0.42, alpha: 1),
    ])!
    gradient.draw(in: shape, angle: -90)

    // Top sheen for depth.
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    let config = NSImage.SymbolConfiguration(pointSize: 420, weight: .medium)
        .applying(.init(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "shippingbox.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let size = symbol.size
        let rect = NSRect(x: (canvas - size.width) / 2, y: (canvas - size.height) / 2 + 10, width: size.width, height: size.height)
        NSGraphicsContext.saveGraphicsState()
        let glyphShadow = NSShadow()
        glyphShadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        glyphShadow.shadowBlurRadius = 18
        glyphShadow.shadowOffset = NSSize(width: 0, height: -8)
        glyphShadow.set()
        symbol.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
    }
    return true
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(x: 0, y: 0, width: canvas, height: canvas))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(filePath: output))
