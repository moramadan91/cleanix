// Renders the app icon (1024 px PNG) in the app's own look: Amber Dusk squircle, glass orb, white sparkles.
// Usage: swift scripts/make_icon.swift <out.png>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255, alpha: a)
}

// Squircle body with Apple's icon margin (824 px shape on a 1024 canvas).
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
ctx.saveGState()
shape.addClip()
NSGradient(colors: [hex(0x3A2540), hex(0x14101C)])!.draw(in: body, angle: -90)
// Warm amber glow from the top.
NSGradient(colors: [hex(0xFFB04A, 0.55), hex(0xFFB04A, 0)])!
    .draw(fromCenter: NSPoint(x: 512, y: 760), radius: 0, toCenter: NSPoint(x: 512, y: 760), radius: 520, options: [])
ctx.restoreGState()

// Glass orb: amber body, top gloss, thin bright rim.
let orbRect = NSRect(x: 252, y: 232, width: 520, height: 520)
let orb = NSBezierPath(ovalIn: orbRect)
ctx.saveGState()
orb.addClip()
NSGradient(colors: [hex(0xFFC46E), hex(0xE07A2E)])!.draw(in: orbRect, angle: -90)
NSGradient(colors: [hex(0xFFFFFF, 0.45), hex(0xFFFFFF, 0)])!
    .draw(in: NSBezierPath(ovalIn: NSRect(x: 320, y: 520, width: 384, height: 216)), angle: -90)
ctx.restoreGState()
hex(0xFFFFFF, 0.55).setStroke()
orb.lineWidth = 6
orb.stroke()

// Sparkles symbol, white, centred on the orb.
let config = NSImage.SymbolConfiguration(pointSize: 250, weight: .semibold)
    .applying(.init(paletteColors: [.white]))
if let symbol = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
    let s = symbol.size
    symbol.draw(in: NSRect(x: 512 - s.width / 2, y: 492 - s.height / 2, width: s.width, height: s.height))
}
image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")
