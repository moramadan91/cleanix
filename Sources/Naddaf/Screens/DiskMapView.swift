import SwiftUI
import NaddafCore

/// Treemap of the home folder: area = size. Click a block to open it; the trail goes back up.
struct DiskMapView: View {
    let section: AppSection

    @State private var trail: [DiskNode] = []
    @State private var scanning = false

    var body: some View {
        if scanning {
            ScanningView()
        } else if let current = trail.last {
            VStack(spacing: 12) {
                breadcrumb
                GeometryReader { geo in
                    let blocks = treemap(current.children, in: CGRect(origin: .zero, size: geo.size))
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                            tile(block.node, index: index, rect: block.rect)
                        }
                    }
                    // Layout is computed in absolute coordinates; keep it from being mirrored in RTL.
                    .environment(\.layoutDirection, .leftToRight)
                }
                HStack {
                    Text("\(current.name): \(formatBytes(current.bytes))").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Button(L("common.reveal")) { revealInFinder(current.url) }.buttonStyle(.glass)
                }
            }
            .padding(.horizontal, 40)
            .padding(.top, 16)
            .padding(.bottom, 28)
        } else {
            IntroHero(section: section) { scan() }
        }
    }

    private var breadcrumb: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(Array(trail.enumerated()), id: \.offset) { index, node in
                    if index > 0 { Image(systemName: "chevron.forward").font(.caption).foregroundStyle(.secondary) }
                    Button(index == 0 ? "~" : node.name) { trail = Array(trail.prefix(index + 1)) }
                        .buttonStyle(.plain)
                        .font(.system(size: 14, weight: index == trail.count - 1 ? .bold : .regular))
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func tile(_ node: DiskNode, index: Int, rect: CGRect) -> some View {
        let canOpen = !node.children.isEmpty
        return RoundedRectangle(cornerRadius: 10)
            .fill(section.tint.mix(with: section.tint2, by: Double(index % 6) / 6).opacity(0.75))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.18)))
            .overlay(alignment: .topLeading) {
                if rect.width > 80 && rect.height > 40 {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(localized("group", node.name)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(formatBytes(node.bytes)).font(.system(size: 11)).opacity(0.8)
                    }
                    .padding(8)
                }
            }
            .frame(width: max(rect.width - 4, 1), height: max(rect.height - 4, 1))
            .offset(x: rect.minX + 2, y: rect.minY + 2)
            .help("\(node.name) — \(formatBytes(node.bytes))")
            .onTapGesture { if canOpen { trail.append(node) } else { revealInFinder(node.url) } }
    }

    private func scan() {
        scanning = true
        let home = AppEnv.shared.home
        Task {
            if let root = try? await Task.detached(operation: { try await buildDiskTree(root: home, depth: 3) }).value {
                trail = [root]
            }
            scanning = false
        }
    }
}

/// Splits the list into two halves of similar total size and cuts the rectangle along its longer side,
/// recursively. Simple, stable, and keeps blocks roughly square.
func treemap(_ nodes: [DiskNode], in rect: CGRect) -> [(node: DiskNode, rect: CGRect)] {
    let nodes = nodes.filter { $0.bytes > 0 }
    guard let first = nodes.first else { return [] }
    if nodes.count == 1 { return [(first, rect)] }
    let total = nodes.reduce(0) { $0 + $1.bytes }
    var acc: Int64 = 0
    var split = 0
    for node in nodes {
        if split > 0 && acc + node.bytes > total / 2 { break }
        acc += node.bytes
        split += 1
    }
    split = min(split, nodes.count - 1)
    let a = Array(nodes[..<split]), b = Array(nodes[split...])
    let fraction = CGFloat(Double(a.reduce(0) { $0 + $1.bytes }) / Double(total))
    let (ra, rb): (CGRect, CGRect)
    if rect.width >= rect.height {
        let w = rect.width * fraction
        ra = CGRect(x: rect.minX, y: rect.minY, width: w, height: rect.height)
        rb = CGRect(x: rect.minX + w, y: rect.minY, width: rect.width - w, height: rect.height)
    } else {
        let h = rect.height * fraction
        ra = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: h)
        rb = CGRect(x: rect.minX, y: rect.minY + h, width: rect.width, height: rect.height - h)
    }
    return treemap(a, in: ra) + treemap(b, in: rb)
}
