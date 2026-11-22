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

/// Launch intro, about 2.4 s, drawn on its own transparent window so only the logo shows on the desktop:
/// the ball drops in, the swoosh sweeps around it, a light passes over the mark, the wordmark wipes in,
/// then the logo lifts away while the app window fades in. Reduce Motion gets a short fade instead.
struct IntroView: View {
    let onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ball = false
    @State private var swoosh = false
    @State private var shine = false
    @State private var word = false
    @State private var leaving = false
    @State private var finished = false

    private let markWidth: CGFloat = 220
    private var markHeight: CGFloat { markWidth * 895 / 1173 }

    var body: some View {
        ZStack {
            VStack(spacing: 34) {
                ZStack {
                    Brand.image("mark-ball").resizable().scaledToFit()
                        .foregroundStyle(Brand.violet)
                        .scaleEffect(ball ? 1 : 0.3)
                        .rotationEffect(.degrees(ball ? 0 : -50))
                        .offset(y: ball ? 0 : -40)
                        .opacity(ball ? 1 : 0)
                    Brand.image("mark-swoosh").resizable().scaledToFit()
                        .foregroundStyle(Brand.violet)
                        .rotationEffect(.degrees(swoosh ? 0 : 35), anchor: .topTrailing)
                        .offset(x: swoosh ? 0 : -70, y: swoosh ? 0 : 50)
                        .opacity(swoosh ? 1 : 0)
                }
                .frame(width: markWidth, height: markHeight)
                // A bright band that slides across the mark once.
                .overlay {
                    LinearGradient(colors: [.clear, .white.opacity(0.85), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 90)
                        .rotationEffect(.degrees(20))
                        .offset(x: shine ? markWidth : -markWidth)
                        .mask {
                            ZStack {
                                Brand.image("mark-ball").resizable().scaledToFit()
                                Brand.image("mark-swoosh").resizable().scaledToFit()
                            }
                            .frame(width: markWidth, height: markHeight)
                        }
                        .opacity(swoosh ? 1 : 0)
                }

                Brand.image("wordmark").resizable().scaledToFit()
                    .foregroundStyle(Brand.violet)
                    .frame(width: 190)
                    // Wipe in from the reading start of the word (left).
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: word ? 200 : 0)
                    }
                    .offset(y: word ? 0 : 12)
                    .opacity(word ? 1 : 0)
            }
            .scaleEffect(leaving ? 1.12 : 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(leaving ? 0 : 1)
        .environment(\.layoutDirection, .leftToRight) // the logo never mirrors
        .task { await play() }
    }

    private func play() async {
        if reduceMotion {
            ball = true; swoosh = true; word = true
            try? await Task.sleep(for: .milliseconds(700))
            withAnimation(.easeOut(duration: 0.3)) { leaving = true }
            return finish()
        }
        try? await Task.sleep(for: .milliseconds(150))
        withAnimation(.spring(duration: 0.7, bounce: 0.35)) { ball = true }
        try? await Task.sleep(for: .milliseconds(330))
        withAnimation(.spring(duration: 0.65, bounce: 0.25)) { swoosh = true }
        try? await Task.sleep(for: .milliseconds(450))
        withAnimation(.easeInOut(duration: 0.6)) { shine = true }
        try? await Task.sleep(for: .milliseconds(200))
        withAnimation(.easeOut(duration: 0.55)) { word = true }
        try? await Task.sleep(for: .milliseconds(900))
        withAnimation(.easeIn(duration: 0.45)) { leaving = true }
        finish() // the app window fades in while the logo leaves
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        onFinish()
    }
}
