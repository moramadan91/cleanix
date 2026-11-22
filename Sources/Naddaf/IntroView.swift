import SwiftUI
import AppKit

/// Brand colours from the Cleanix identity.
enum Brand {
    static let violet = Color(red: 0x60 / 255, green: 0x35 / 255, blue: 0xF5 / 255)
    static let lavender = Color(red: 0xEA / 255, green: 0xE4 / 255, blue: 0xFF / 255)
    static let charcoal = Color(red: 0x17 / 255, green: 0x12 / 255, blue: 0x22 / 255)

    /// White-on-transparent logo pieces cut by scripts/extract_logo.py.
    static func image(_ name: String) -> Image {
        let url = Bundle.module.url(forResource: name, withExtension: "png")
            ?? Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Brand")
        let ns = url.flatMap(NSImage.init(contentsOf:)) ?? NSImage()
        return Image(nsImage: ns).renderingMode(.template)
    }
}

/// Launch intro, about 2.5 s, drawn on its own transparent window so only the logo shows on the desktop.
/// A glitch sequence, computed from elapsed time alone (seeded noise, no state between frames):
/// the mark tears in with an RGB split and settles, the wordmark builds in band by band, two short
/// glitch hits, then the logo collapses like a CRT switching off while the app window fades in.
/// Reduce Motion gets the still logo and a short fade.
struct IntroView: View {
    let onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date.now

    static let exitAt = 2.2
    private static let exitLength = 0.3
    private let markWidth: CGFloat = 220
    private var markHeight: CGFloat { markWidth * 895 / 1173 }
    private let wordWidth: CGFloat = 190
    private var wordHeight: CGFloat { wordWidth * 379 / 1545 }

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { ctx in
            let t = reduceMotion ? 1.9 : ctx.date.timeIntervalSince(start)
            frame(t)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.layoutDirection, .leftToRight) // the logo never mirrors
        .task {
            try? await Task.sleep(for: .seconds(reduceMotion ? 0.9 : Self.exitAt))
            onFinish() // the app window fades in while the logo leaves
        }
    }

    private func frame(_ t: Double) -> some View {
        let g = glitch(t)
        let exit = reduceMotion ? 0 : min(max((t - Self.exitAt) / Self.exitLength, 0), 1)
        // Mark: hidden for a beat, then flickers in (a few steps only, well under 3 flashes a second).
        let markOn = t > 0.08 && (t > 0.32 || noise(7, Int(t * 10), 0) > 0.3)
        let markScale = 1 + 0.12 * max(0, 1 - t / 0.45)
        return VStack(spacing: 34) {
            GlitchLayer(name: "mark", size: CGSize(width: markWidth, height: markHeight),
                        amp: g.amp, split: g.split, step: g.step, seed: 1, bands: 10, revealAt: nil, t: t)
                .scaleEffect(markScale)
                .opacity(markOn ? 1 : 0)
            GlitchLayer(name: "wordmark", size: CGSize(width: wordWidth, height: wordHeight),
                        amp: g.amp * 0.7, split: g.split * 0.8, step: g.step, seed: 2, bands: 6,
                        revealAt: { i in 0.85 + Double(Self.order[i]) * 0.07 }, t: t)
        }
        // CRT off: squash to a line, stretch a little, then go.
        .scaleEffect(x: 1 + 0.35 * exit, y: max(0.015, 1 - 1.6 * exit))
        .opacity(exit > 0.6 ? 1 - (exit - 0.6) / 0.4 : 1)
    }

    private static let order = [3, 0, 5, 2, 4, 1]

    /// Tear amount and RGB split at time t: a strong entry that settles, then two short hits.
    private func glitch(_ t: Double) -> (amp: Double, split: Double, step: Int) {
        if reduceMotion { return (0, 0, 0) }
        var amp = 70 * pow(max(0, 1 - t / 0.55), 2)
        var split = 16 * max(0, 1 - t / 0.65)
        for (at, len, a, s) in [(1.25, 0.14, 30.0, 11.0), (1.9, 0.1, 18.0, 7.0)] where t >= at && t < at + len {
            amp += a; split += s
        }
        return (amp, split, Int(t * 24)) // the tear jumps at 24 steps a second, like real signal noise
    }
}

/// One logo piece cut into horizontal bands that tear sideways, over two colour-split copies.
private struct GlitchLayer: View {
    let name: String
    let size: CGSize
    let amp: Double
    let split: Double
    let step: Int
    let seed: Int
    let bands: Int
    /// When each band first appears (nil: all at once).
    let revealAt: ((Int) -> Double)?
    let t: Double

    var body: some View {
        let bh = size.height / CGFloat(bands)
        ZStack {
            if split > 0.5 {
                piece(Color(red: 0.24, green: 0.95, blue: 1)).offset(x: -split, y: split * 0.15).opacity(0.85)
                piece(Color(red: 1, green: 0.31, blue: 0.85)).offset(x: split, y: -split * 0.15).opacity(0.85)
            }
            ForEach(0..<bands, id: \.self) { i in
                let shown = revealAt.map { t >= $0(i) } ?? true
                let since = revealAt.map { t - $0(i) } ?? 1
                // A new band arrives torn and snaps into place; afterwards only some bands tear.
                let arrive = since < 0.22 ? (noise(seed, i, 99) - 0.5) * 80 * (1 - since / 0.22) : 0
                let tear = noise(seed + 10, i, step) < 0.45 ? (noise(seed, i, step) - 0.5) * 2 * amp : 0
                piece(Brand.violet)
                    .mask {
                        Rectangle().frame(width: size.width * 2, height: bh + 0.5)
                            .position(x: size.width / 2, y: bh * (CGFloat(i) + 0.5))
                    }
                    .offset(x: arrive + tear)
                    .opacity(shown ? 1 : 0)
            }
        }
        .frame(width: size.width, height: size.height)
        .opacity(revealAt == nil || t >= revealAt!(0) - 0.25 ? 1 : 0)
    }

    private func piece(_ color: Color) -> some View {
        Brand.image(name).resizable().scaledToFit().foregroundStyle(color)
            .frame(width: size.width, height: size.height)
    }
}

/// Seeded noise in [0, 1): mulberry32 on a hash of the inputs, so a given frame always looks the same.
private func noise(_ a: Int, _ b: Int, _ c: Int) -> Double {
    var z = UInt32(truncatingIfNeeded: a &* 73_856_093 ^ b &* 19_349_663 ^ c &* 83_492_791) &+ 0x6D2B_79F5
    z = (z ^ (z >> 15)) &* (z | 1)
    z ^= z &+ ((z ^ (z >> 7)) &* (z | 61))
    return Double(z ^ (z >> 14)) / 4_294_967_296
}
