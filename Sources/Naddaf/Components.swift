import SwiftUI
import AppKit

/// Static, rich gradient per section. It never animates by itself, only crossfades when the
/// section changes: a continuously moving background measured 3.9% idle CPU, so it stays still.
struct AuroraBackground: View {
    let section: AppSection
    @Environment(\.layoutDirection) private var direction

    var body: some View {
        ZStack {
            Theme.bg
            LinearGradient(colors: [section.tint.opacity(0.78), section.tint2.opacity(0.40), .clear],
                           startPoint: .topLeading, endPoint: .bottom)
            RadialGradient(colors: [section.tint2.opacity(0.65), .clear], center: .bottomTrailing,
                           startRadius: 0, endRadius: 760)
            // Soft spotlight behind the hero icon (the hero sits at the trailing side).
            RadialGradient(colors: [.white.opacity(0.13), .clear],
                           center: UnitPoint(x: direction == .rightToLeft ? 0.25 : 0.75, y: 0.45),
                           startRadius: 0, endRadius: 460)
        }
        .ignoresSafeArea()
        .id(section)
        .transition(.opacity)
    }
}

/// Large hero: a soft glow and a 3D glass tablet holding a matte white symbol (`GlassBadge`).
/// Everything is baked into bitmaps once and moved by Core Animation, so it costs almost no CPU.
struct SectionHero: View {
    let section: AppSection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private var live: Bool { scenePhase == .active && !reduceMotion }

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [section.tint.opacity(0.40), .clear], center: .center,
                                     startRadius: 30, endRadius: 270))
                .frame(width: 540, height: 540)
            GlassBadge(symbol: section.symbol, shape: section.slab, motion: section.motion, live: live,
                       tint: section.tint, deep: section.tint2)
                .frame(width: 440, height: 440)
        }
        .frame(width: 460, height: 460)
        // Purely decorative. Its glow is larger than its frame and used to swallow clicks on the tabs above.
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Outline of a section's glass tablet.
enum SlabShape {
    case circle, hexagon, octagon, squircle

    func path(in r: CGRect) -> CGPath {
        switch self {
        case .circle: return CGPath(ellipseIn: r, transform: nil)
        case .squircle: return CGPath(roundedRect: r, cornerWidth: r.width * 0.26, cornerHeight: r.width * 0.26, transform: nil)
        case .hexagon: return Self.polygon(sides: 6, in: r, rotation: .pi / 6, corner: r.width * 0.12)
        case .octagon: return Self.polygon(sides: 8, in: r, rotation: .pi / 8, corner: r.width * 0.07)
        }
    }

    /// Regular polygon with rounded corners.
    private static func polygon(sides: Int, in r: CGRect, rotation: CGFloat, corner: CGFloat) -> CGPath {
        let c = CGPoint(x: r.midX, y: r.midY)
        let radius = min(r.width, r.height) / 2
        let pts = (0..<sides).map { i -> CGPoint in
            let a = rotation + CGFloat(i) * 2 * .pi / CGFloat(sides)
            return CGPoint(x: c.x + radius * cos(a), y: c.y + radius * sin(a))
        }
        let path = CGMutablePath()
        let mid = { (p: CGPoint, q: CGPoint) in CGPoint(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2) }
        path.move(to: mid(pts[sides - 1], pts[0]))
        for i in 0..<sides {
            path.addArc(tangent1End: pts[i], tangent2End: pts[(i + 1) % sides], radius: corner)
        }
        path.closeSubpath()
        return path
    }
}

extension AppSection {
    var slab: SlabShape {
        switch self {
        case .overview, .diskMap, .cloud: .circle
        case .smartScan, .performance: .hexagon
        case .protection, .clutter: .octagon
        case .cleanup, .apps: .squircle
        }
    }
}

struct GlassBadge: NSViewRepresentable {
    let symbol: String
    let shape: SlabShape
    let motion: SymbolMotion
    let live: Bool
    let tint: Color
    let deep: Color

    func makeNSView(context: Context) -> BadgeHostView { BadgeHostView() }

    func updateNSView(_ view: BadgeHostView, context: Context) {
        view.configure(symbol: symbol, shape: shape, motion: motion, live: live, tint: NSColor(tint), deep: NSColor(deep))
    }
}

/// Host for the glass tablet (static bitmap) and the symbol (bitmap that moves). Both sit in a
/// 3D transform layer that tilts slowly, with the symbol floating a little in front of the glass.
final class BadgeHostView: NSView {
    private let stage = CATransformLayer()
    private let slabLayer = CALayer()
    private let iconLayer = CALayer()
    private var key = ""
    private var motion = SymbolMotion.pulse
    private var live = false
    private var anchor = CGPoint(x: 0.5, y: 0.5)
    private var iconSize = CGSize.zero

    private let width: CGFloat = 250      // tablet face
    private let thickness: CGFloat = 22   // tablet edge
    private let pointSize: CGFloat = 106  // symbol

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / 900
        layer?.sublayerTransform = perspective
        layer?.addSublayer(stage)
        stage.addSublayer(slabLayer)
        stage.addSublayer(iconLayer)
        iconLayer.zPosition = 36
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var scale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    func configure(symbol: String, shape: SlabShape, motion: SymbolMotion, live: Bool, tint: NSColor, deep: NSColor) {
        let newKey = "\(symbol)|\(shape)|\(tint)|\(deep)"
        let changed = newKey != key || motion != self.motion || live != self.live
        let needsImages = newKey != key
        key = newKey; self.motion = motion; self.live = live
        guard changed else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if needsImages {
            if let slab = renderSlab(shape: shape, tint: tint, deep: deep) {
                slabLayer.contents = slab.image
                slabLayer.bounds = CGRect(origin: .zero, size: slab.size)
                slabLayer.contentsScale = scale
            }
            if let icon = renderSymbol(symbol, tint: tint, deep: deep) {
                iconLayer.contents = icon.image
                iconSize = icon.size
                iconLayer.bounds = CGRect(origin: .zero, size: icon.size)
                iconLayer.contentsScale = scale
            }
        }
        anchor = motion == .wiggle ? CGPoint(x: 0.5, y: 0.2) : CGPoint(x: 0.5, y: 0.5)
        iconLayer.anchorPoint = anchor
        place()
        CATransaction.commit()
        animate()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        place()
        CATransaction.commit()
    }

    private func place() {
        stage.bounds = bounds
        stage.position = CGPoint(x: bounds.midX, y: bounds.midY)
        slabLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        // The tablet's face sits half a thickness above the bitmap centre (the edge hangs below it).
        let face = CGPoint(x: bounds.midX, y: bounds.midY + thickness / 2)
        iconLayer.position = CGPoint(x: face.x, y: face.y + (anchor.y - 0.5) * iconSize.height)
    }

    private func context(_ size: CGSize) -> CGContext? {
        let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.scaleBy(x: scale, y: scale)
        return ctx
    }

    private func gradient(_ colors: [NSColor], _ locations: [CGFloat]) -> CGGradient? {
        CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors.map(\.cgColor) as CFArray, locations: locations)
    }

    /// Glass tablet: soft tinted shadow, a translucent edge, a lit face, a bright rim and a gloss band.
    private func renderSlab(shape: SlabShape, tint: NSColor, deep: NSColor) -> (image: CGImage, size: CGSize)? {
        let pad: CGFloat = 60
        let size = CGSize(width: width + pad * 2, height: width + thickness + pad * 2)
        guard let ctx = context(size) else { return nil }
        let face = CGRect(x: pad, y: pad + thickness, width: width, height: width)
        let path = shape.path(in: face)
        func shifted(_ dy: CGFloat) -> CGPath {
            var t = CGAffineTransform(translationX: 0, y: dy)
            return path.copy(using: &t) ?? path
        }
        let light = tint.blended(withFraction: 0.5, of: .white) ?? tint
        let dark = deep.blended(withFraction: 0.35, of: .black) ?? deep

        // Shadow cast by the whole tablet, tinted rather than grey.
        ctx.setShadow(offset: CGSize(width: 0, height: -22), blur: 46, color: dark.withAlphaComponent(0.75).cgColor)
        ctx.addPath(shifted(-thickness)); ctx.setFillColor(dark.cgColor); ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)

        // Edge: layers from the bottom (deep) up to the face (lighter), like thick coloured glass.
        let steps = Int(thickness)
        for i in 0...steps {
            let f = CGFloat(i) / CGFloat(steps)
            let c = (dark.blended(withFraction: f * 0.85, of: tint) ?? tint).withAlphaComponent(0.92)
            ctx.addPath(shifted(-thickness + CGFloat(i))); ctx.setFillColor(c.cgColor); ctx.fillPath()
        }
        ctx.addPath(shifted(-thickness)); ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.22).cgColor)
        ctx.setLineWidth(1.5); ctx.strokePath()

        // Face: light at the top, deep at the bottom, a glow behind where the symbol sits, a gloss band on top.
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        if let g = gradient([light, tint, deep], [0, 0.5, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: face.midX, y: face.maxY), end: CGPoint(x: face.midX, y: face.minY), options: [])
        }
        if let g = gradient([NSColor.white.withAlphaComponent(0.38), NSColor.white.withAlphaComponent(0)], [0, 1]) {
            ctx.drawRadialGradient(g, startCenter: CGPoint(x: face.midX, y: face.midY + width * 0.12), startRadius: 0,
                                   endCenter: CGPoint(x: face.midX, y: face.midY + width * 0.12), endRadius: width * 0.55, options: [])
        }
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.10).cgColor)
        ctx.fillEllipse(in: CGRect(x: face.minX - width * 0.2, y: face.maxY - width * 0.34, width: width * 1.4, height: width * 0.6))
        ctx.restoreGState()

        // Rim: bright at the top, fading down, so the face reads as polished glass.
        ctx.saveGState()
        ctx.addPath(path); ctx.setLineWidth(4); ctx.replacePathWithStrokedPath(); ctx.clip()
        if let g = gradient([NSColor.white.withAlphaComponent(0.9), NSColor.white.withAlphaComponent(0.08), light.withAlphaComponent(0.5)], [0, 0.55, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: face.midX, y: face.maxY), end: CGPoint(x: face.midX, y: face.minY), options: [])
        }
        ctx.restoreGState()
        // Inner bevel line.
        var inset = CGAffineTransform(translationX: face.midX, y: face.midY).scaledBy(x: 0.93, y: 0.93).translatedBy(x: -face.midX, y: -face.midY)
        if let inner = path.copy(using: &inset) {
            ctx.addPath(inner); ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.14).cgColor); ctx.setLineWidth(1); ctx.strokePath()
        }
        guard let image = ctx.makeImage() else { return nil }
        return (image, size)
    }

    private func symbolImage(_ name: String, _ color: NSColor) -> (CGImage, CGSize)? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return (cg, image.size)
    }

    /// Matte white symbol with a little thickness and a soft tinted contact shadow on the glass.
    private func renderSymbol(_ name: String, tint: NSColor, deep: NSColor) -> (image: CGImage, size: CGSize)? {
        let sideColor = NSColor.white.blended(withFraction: 0.4, of: tint) ?? tint
        guard let (face, size) = symbolImage(name, .white), let (side, _) = symbolImage(name, sideColor) else { return nil }
        let pad: CGFloat = 34
        let depth = (pointSize * 0.06).rounded()
        let canvas = CGSize(width: size.width + pad * 2, height: size.height + depth + pad * 2)
        guard let ctx = context(canvas) else { return nil }
        let top = CGRect(x: pad, y: pad + depth, width: size.width, height: size.height)

        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 18,
                      color: (deep.blended(withFraction: 0.4, of: .black) ?? deep).withAlphaComponent(0.6).cgColor)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        for i in 0..<Int(depth) { ctx.draw(side, in: top.offsetBy(dx: 0, dy: -depth + CGFloat(i))) }
        ctx.draw(face, in: top)
        ctx.endTransparencyLayer()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)

        // Soft matte shading on the face: pure white on top, a hint of the section hue lower down.
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.draw(face, in: top)
        ctx.setBlendMode(.sourceIn)
        if let g = gradient([.white, NSColor.white.blended(withFraction: 0.22, of: tint) ?? .white], [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: top.midX, y: top.maxY), end: CGPoint(x: top.midX, y: top.minY), options: [])
        }
        ctx.endTransparencyLayer()
        guard let image = ctx.makeImage() else { return nil }
        return (image, canvas)
    }

    private func animate() {
        stage.removeAllAnimations()
        iconLayer.removeAllAnimations()
        let tilt = CATransform3DMakeRotation(0.28, 1, 0, 0)
        stage.transform = tilt
        guard live else { return }

        // The tablet turns slowly left and right, so the glass edge and the floating symbol shift (parallax).
        let sway = CABasicAnimation(keyPath: "transform")
        sway.fromValue = CATransform3DRotate(tilt, -0.24, 0, 1, 0)
        sway.toValue = CATransform3DRotate(tilt, 0.24, 0, 1, 0)
        sway.duration = 4.6
        sway.autoreverses = true
        sway.repeatCount = .infinity
        sway.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        stage.add(sway, forKey: "sway")

        let cycle: CFTimeInterval = 3.2
        func keyframes(_ path: String, _ values: [Double], _ times: [Double]) -> CAKeyframeAnimation {
            let a = CAKeyframeAnimation(keyPath: path)
            a.values = values
            a.keyTimes = times.map { NSNumber(value: $0) }
            a.calculationMode = .cubic
            a.duration = cycle
            a.repeatCount = .infinity
            return a
        }
        switch motion {
        case .wiggle:
            iconLayer.add(keyframes("transform.rotation.z", [0, -0.30, 0.26, -0.20, 0.14, 0, 0],
                                    [0, 0.08, 0.16, 0.24, 0.32, 0.42, 1]), forKey: "wave")
        case .bounce:
            iconLayer.add(keyframes("transform.translation.y", [0, 18, 0, 7, 0, 0], [0, 0.12, 0.24, 0.32, 0.40, 1]), forKey: "bounce")
        case .pulse:
            iconLayer.add(keyframes("transform.scale", [1, 1.12, 1, 1], [0, 0.18, 0.36, 1]), forKey: "scale")
        case .variable:
            iconLayer.add(keyframes("transform.scale", [1, 1.09, 1, 1.09, 1, 1], [0, 0.14, 0.28, 0.42, 0.56, 1]), forKey: "scale")
            iconLayer.add(keyframes("transform.rotation.z", [0, 0.10, 0, -0.10, 0, 0], [0, 0.14, 0.28, 0.42, 0.56, 1]), forKey: "tilt")
        }
    }
}
