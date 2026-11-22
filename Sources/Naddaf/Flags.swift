import SwiftUI

struct ArabLeagueFlag: View {
    var body: some View {
        Canvas { context, size in
            let green = Color(red: 0, green: 0.48, blue: 0.24)
            let center = size.width / 2
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(green))

            // The overlapping green ellipse opens the crescent upward.
            context.fill(Path(ellipseIn: CGRect(x: center - 5, y: 2.5, width: 10, height: 10)), with: .color(.white))
            context.fill(Path(ellipseIn: CGRect(x: center - 4.25, y: 1, width: 8.5, height: 9)), with: .color(green))
            context.stroke(Path(ellipseIn: CGRect(x: center - 2, y: 4.5, width: 4, height: 4)), with: .color(.white), lineWidth: 0.7)
        }
        .flagFrame()
    }
}

struct UnionJackFlag: View {
    var body: some View {
        Canvas { context, size in
            let blue = Color(red: 0.01, green: 0.13, blue: 0.41)
            let red = Color(red: 0.78, green: 0.06, blue: 0.18)
            let midX = size.width / 2
            let midY = size.height / 2
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(blue))

            let diagonals = Path { path in
                path.move(to: .zero)
                path.addLine(to: CGPoint(x: size.width, y: size.height))
                path.move(to: CGPoint(x: 0, y: size.height))
                path.addLine(to: CGPoint(x: size.width, y: 0))
            }
            context.stroke(diagonals, with: .color(.white), lineWidth: 3.3)

            // The red diagonals are offset on each side of the central cross.
            let redDiagonals = Path { path in
                path.move(to: CGPoint(x: 0, y: 0.75))
                path.addLine(to: CGPoint(x: midX, y: midY + 0.75))
                path.move(to: CGPoint(x: 0, y: size.height + 0.75))
                path.addLine(to: CGPoint(x: midX, y: midY + 0.75))
                path.move(to: CGPoint(x: size.width, y: -0.75))
                path.addLine(to: CGPoint(x: midX, y: midY - 0.75))
                path.move(to: CGPoint(x: size.width, y: size.height - 0.75))
                path.addLine(to: CGPoint(x: midX, y: midY - 0.75))
            }
            context.stroke(redDiagonals, with: .color(red), lineWidth: 1.25)

            let cross = Path { path in
                path.move(to: CGPoint(x: 0, y: midY))
                path.addLine(to: CGPoint(x: size.width, y: midY))
                path.move(to: CGPoint(x: midX, y: 0))
                path.addLine(to: CGPoint(x: midX, y: size.height))
            }
            context.stroke(cross, with: .color(.white), lineWidth: 4.8)
            context.stroke(cross, with: .color(red), lineWidth: 2.8)
        }
        .flagFrame()
    }
}

private extension View {
    func flagFrame() -> some View {
        let outline = RoundedRectangle(cornerRadius: 3)
        return frame(width: 22, height: 15)
            .clipShape(outline)
            .overlay { outline.strokeBorder(.white, lineWidth: 0.25) }
            .accessibilityHidden(true)
    }
}
