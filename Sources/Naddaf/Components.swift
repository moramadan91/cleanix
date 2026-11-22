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
            LiveSymbol(name: section.symbol, pointSize: 116, motion: section.motion, live: live)
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

    func makeNSView(context: Context) -> SymbolHostView { SymbolHostView() }

    func updateNSView(_ view: SymbolHostView, context: Context) {
        view.configure(name: name, pointSize: pointSize, motion: motion, live: live)
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
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(name: String, pointSize: CGFloat, motion: SymbolMotion, live: Bool) {
        let needsImage = name != self.name || pointSize != self.pointSize
        let changed = needsImage || motion != self.motion || live != self.live
        self.name = name; self.pointSize = pointSize; self.motion = motion; self.live = live
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

    private func renderImage() {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        iconSize = image.size
        iconLayer.contents = cg
        iconLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        iconLayer.bounds = CGRect(origin: .zero, size: iconSize)
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
