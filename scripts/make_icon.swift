// Renders the app icon (1024 px PNG): Electric Violet squircle with the white Cleanix mark.
// Usage: swift scripts/make_icon.swift <mark.png> <out.png>
import AppKit

let markPath = CommandLine.arguments[1]
let out = CommandLine.arguments[2]
let size: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255, alpha: a)
}

// Squircle with Apple's icon margin (824 px shape on a 1024 canvas).
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
shape.addClip()
NSGradient(colors: [hex(0x7A55FF), hex(0x6035F5), hex(0x3F1DB8)])!.draw(in: body, angle: -90)
// Soft lavender light from the top left.
NSGradient(colors: [hex(0xEAE4FF, 0.35), hex(0xEAE4FF, 0)])!
    .draw(fromCenter: NSPoint(x: 330, y: 820), radius: 0, toCenter: NSPoint(x: 330, y: 820), radius: 560, options: [])
NSGraphicsContext.restoreGraphicsState()

// The white mark, centred, about 62% of the squircle wide.
let mark = NSImage(contentsOfFile: markPath)!
let w: CGFloat = 520
let h = w * mark.size.height / mark.size.width
mark.draw(in: NSRect(x: 512 - w / 2, y: 512 - h / 2, width: w, height: h))

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")
