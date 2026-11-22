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

/// Large layered hero: glow, rings, glass satellites and a glass orb holding the section symbol.
/// The symbol moves continuously through `LiveSymbol` (Core Animation), which costs almost no CPU.
struct SectionHero: View {
    let section: AppSection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private var live: Bool { scenePhase == .active && !reduceMotion }

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [section.tint2.opacity(0.60), .clear], center: .center,
                                     startRadius: 30, endRadius: 270))
                .frame(width: 540, height: 540)
            Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1).frame(width: 420, height: 420)
            Circle().strokeBorder(.white.opacity(0.10), lineWidth: 1).frame(width: 340, height: 340)
            satellite(size: 36, x: 150, y: -178)
            satellite(size: 20, x: -196, y: 96)
            satellite(size: 28, x: 176, y: 150)
            icon
        }
        .frame(width: 460, height: 460)
        // Purely decorative. Its glow is larger than its frame and used to swallow clicks on the tabs above.
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func satellite(size: CGFloat, x: CGFloat, y: CGFloat) -> some View {
        Color.clear
            .frame(width: size, height: size)
            .glassEffect(.regular.tint(section.tint.opacity(0.55)), in: .circle)
            .offset(x: x, y: y)
    }

    /// Glass orb and glow are static layers; only the symbol on top moves.
    private var icon: some View {
        ZStack {
            Circle()
                .fill(section.tint2.opacity(0.55))
                .frame(width: 250, height: 250)
                .blur(radius: 30)
            Color.clear
                .frame(width: 250, height: 250)
                .glassEffect(.regular.tint(section.tint.opacity(0.55)), in: .circle)
            LiveSymbol(name: section.symbol, pointSize: 116, motion: section.motion, live: live,
                       tint: section.tint, deep: section.tint2)
                .frame(width: 250, height: 250)
        }
    }
}

/// An SF Symbol drawn once into a bitmap layer and moved with Core Animation keyframes.
/// The compositor only transforms the finished bitmap, so a forever-looping animation stays cheap
/// (the SF Symbols effects looped through SwiftUI cost about 20% idle CPU).
struct LiveSymbol: NSViewRepresentable {
    let name: String
    let pointSize: CGFloat
    let motion: SymbolMotion
    let live: Bool
    var tint: Color = .white
    var deep: Color = .gray

    func makeNSView(context: Context) -> SymbolHostView { SymbolHostView() }

    func updateNSView(_ view: SymbolHostView, context: Context) {
        view.configure(name: name, pointSize: pointSize, motion: motion, live: live,
                       tint: NSColor(tint), deep: NSColor(deep))
    }
}

final class SymbolHostView: NSView {
    private let iconLayer = CALayer()
    private var name = ""
    private var pointSize: CGFloat = 0
    private var motion: SymbolMotion = .pulse
    private var live = false
    private var anchor = CGPoint(x: 0.5, y: 0.5)
    private var iconSize = CGSize.zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(iconLayer)
        // Perspective, so the slow sideways sway reads as a 3D turn rather than a squash.
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / 700
        layer?.sublayerTransform = perspective
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var tint = NSColor.white
    private var deep = NSColor.gray

    func configure(name: String, pointSize: CGFloat, motion: SymbolMotion, live: Bool, tint: NSColor, deep: NSColor) {
        let needsImage = name != self.name || pointSize != self.pointSize || tint != self.tint || deep != self.deep
        let changed = needsImage || motion != self.motion || live != self.live
        self.name = name; self.pointSize = pointSize; self.motion = motion; self.live = live
        self.tint = tint; self.deep = deep
        guard changed else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if needsImage { renderImage() }
        anchor = motion == .wiggle ? CGPoint(x: 0.5, y: 0.1) : CGPoint(x: 0.5, y: 0.5)
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

    private func symbol(_ color: NSColor) -> (CGImage, CGSize)? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return (cg, image.size)
    }

    /// Bakes a liquid-glass symbol into ONE bitmap (drawn once, so the looping motion stays free):
    /// a soft luminous halo in the section hue, a see-through frosted body, a bright rim on the
    /// upper edge and a glossy reflection across the top. No drop shadow, no extrusion.
    private func renderImage() {
        guard let (face, size) = symbol(.white) else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let pad: CGFloat = 32
        let canvas = CGSize(width: size.width + pad * 2, height: size.height + pad * 2)
        guard let ctx = CGContext(data: nil, width: Int(canvas.width * scale), height: Int(canvas.height * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.scaleBy(x: scale, y: scale)
        let rect = CGRect(x: pad, y: pad, width: size.width, height: size.height)
        let space = CGColorSpace(name: CGColorSpace.sRGB)
        let rim = max(1.5, pointSize * 0.018)

        // Halo: light passing through tinted glass, centred (not offset like a shadow).
        ctx.setShadow(offset: .zero, blur: 26, color: tint.withAlphaComponent(0.75).cgColor)
        ctx.setAlpha(0.35)
        ctx.draw(face, in: rect)
        ctx.setAlpha(1)
        ctx.setShadow(offset: .zero, blur: 0, color: nil)

        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        // Body: frosted, more opaque at the top, clearer at the bottom so the orb shows through.
        ctx.draw(face, in: rect)
        ctx.setBlendMode(.sourceIn)
        let body = [NSColor.white.withAlphaComponent(0.95).cgColor,
                    (tint.blended(withFraction: 0.7, of: .white) ?? tint).withAlphaComponent(0.55).cgColor]
        if let g = CGGradient(colorsSpace: space, colors: body as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
        }
        // Rim: everything except the symbol shifted down a little = a bright upper edge.
        ctx.setBlendMode(.sourceAtop)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(rect.insetBy(dx: -pad, dy: -pad))
        ctx.setBlendMode(.destinationOut)
        ctx.draw(face, in: rect.offsetBy(dx: 0, dy: -rim))
        ctx.endTransparencyLayer()
        // Gloss: a soft diagonal reflection over the upper half.
        ctx.setBlendMode(.sourceAtop)
        let gloss = [NSColor.white.withAlphaComponent(0.45).cgColor, NSColor.white.withAlphaComponent(0).cgColor]
        if let g = CGGradient(colorsSpace: space, colors: gloss as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: rect.minX, y: rect.maxY),
                                   end: CGPoint(x: rect.midX, y: rect.midY), options: [])
        }
        ctx.endTransparencyLayer()

        guard let baked = ctx.makeImage() else { return }
        iconSize = canvas
        iconLayer.contents = baked
        iconLayer.contentsScale = scale
        iconLayer.bounds = CGRect(origin: .zero, size: canvas)
    }

    private func place() {
        iconLayer.position = CGPoint(x: bounds.midX, y: bounds.midY + (anchor.y - 0.5) * iconSize.height)
    }

    private func animate() {
        iconLayer.removeAllAnimations()
        guard live else { return }
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

        // Slow sideways turn on every icon, so the extruded side shows: reads as a solid object.
        let sway = keyframes("transform.rotation.y", [0, 0.32, 0, -0.32, 0], [0, 0.25, 0.5, 0.75, 1])
        sway.duration = cycle * 2
        iconLayer.add(sway, forKey: "sway")

        switch motion {
        case .wiggle: // a wave: swings around the base, then rests
            iconLayer.add(keyframes("transform.rotation.z",
                                    [0, -0.40, 0.36, -0.30, 0.22, -0.10, 0, 0],
                                    [0, 0.08, 0.16, 0.24, 0.32, 0.40, 0.48, 1]), forKey: "wave")
        case .bounce:
            iconLayer.add(keyframes("transform.translation.y",
                                    [0, 30, 0, 12, 0, 0], [0, 0.12, 0.24, 0.32, 0.40, 1]), forKey: "bounce")
        case .pulse:
            iconLayer.add(keyframes("transform.scale", [1, 1.16, 1, 1], [0, 0.18, 0.36, 1]), forKey: "scale")
            iconLayer.add(keyframes("opacity", [1, 0.78, 1, 1], [0, 0.18, 0.36, 1]), forKey: "fade")
        case .variable:
            iconLayer.add(keyframes("transform.scale", [1, 1.12, 1, 1.12, 1, 1], [0, 0.14, 0.28, 0.42, 0.56, 1]), forKey: "scale")
            iconLayer.add(keyframes("transform.rotation.z", [0, 0.14, 0, -0.14, 0, 0], [0, 0.14, 0.28, 0.42, 0.56, 1]), forKey: "tilt")
        }
    }
}
