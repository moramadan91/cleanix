import SwiftUI
import AppKit
import NaddafCore

/// Disk Map: a list of what is in the current folder (with a safety label on each entry)
/// next to a simple bubble view where size = area. Click to open a folder; tick and remove
/// what is safe or reviewed. Entries marked "do not delete" cannot be ticked.
struct DiskMapView: View {
    let section: AppSection

    @State private var trail: [DiskNode] = []
    @State private var scanning = false
    @State private var selected: Set<URL> = []
    @State private var showPreview = false
    @State private var result: CleanResult?

    private var home: URL { AppEnv.shared.home }

    var body: some View {
        if scanning {
            ScanningView()
        } else if let result {
            DoneView(result: result) { self.result = nil; scan() }
        } else if let current = trail.last {
            content(current)
        } else {
            IntroHero(section: section) { scan() }
        }
    }

    private func entries(_ node: DiskNode) -> [DiskNode] {
        // "Other" folds tiny entries and points at the parent folder: never offer it for removal.
        node.children.filter { $0.bytes > 0 }
    }

    private func isOther(_ node: DiskNode, in parent: DiskNode) -> Bool { node.url == parent.url }

    private func content(_ current: DiskNode) -> some View {
        let list = entries(current)
        let chosen = list.filter { selected.contains($0.url) && !isOther($0, in: current) }
        return VStack(spacing: 14) {
            header(current)
            HStack(alignment: .top, spacing: 28) {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(list, id: \.url) { row($0, parent: current) }
                    }
                }
                .scrollIndicators(.hidden)
                .glassPanel()
                .frame(maxWidth: .infinity)

                BubbleChart(nodes: Array(list.prefix(8)), tint: section.tint, deep: section.tint2) { node in
                    if !node.children.isEmpty && !isOther(node, in: current) { open(node) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(current.name): \(formatBytes(current.bytes))").font(.system(size: 15, weight: .semibold))
                    let safe = SpaceAdvice.safeBytes(current, home: home)
                    if safe > 0 {
                        Text(String(format: L("map.safeInside"), formatBytes(safe)))
                            .font(.system(size: 13)).foregroundStyle(SafetyBadge.color(.safe))
                    }
                }
                Spacer()
                ActionButton(title: L("map.remove"), disabled: chosen.isEmpty) { showPreview = true }
            }
        }
        .padding(.horizontal, 40)
        .padding(.top, 14)
        .padding(.bottom, 24)
        .sheet(isPresented: $showPreview) {
            let items = chosen.map {
                ScanItem(url: $0.url, bytes: $0.bytes, reason: "Disk Map",
                         safety: SpaceAdvice.safety(of: $0.url, home: home), group: current.name)
            }
            PreviewSheet(items: items, disposal: .trash) { remove($0) }
        }
    }

    private func header(_ current: DiskNode) -> some View {
        HStack(spacing: 10) {
            Button { trail.removeLast(); selected = [] } label: {
                Image(systemName: "chevron.backward").font(.system(size: 14, weight: .bold)).frame(width: 30, height: 30)
            }
            .buttonStyle(.liquid())
            .disabled(trail.count < 2)
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(Array(trail.enumerated()), id: \.offset) { index, node in
                        if index > 0 { Image(systemName: "chevron.forward").font(.caption).foregroundStyle(.secondary) }
                        Button(index == 0 ? "~" : node.name) { trail = Array(trail.prefix(index + 1)); selected = [] }
                            .buttonStyle(.plain)
                            .font(.system(size: 15, weight: index == trail.count - 1 ? .bold : .regular))
                    }
                }
            }
            .scrollIndicators(.hidden)
            Button(L("common.reveal")) { revealInFinder(current.url) }.buttonStyle(.liquid())
        }
    }

    private func row(_ node: DiskNode, parent: DiskNode) -> some View {
        let other = isOther(node, in: parent)
        let safety = other ? Safety.review : SpaceAdvice.safety(of: node.url, home: home)
        let canTick = !other && safety != .risky
        let safeInside = safety == .safe ? 0 : SpaceAdvice.safeBytes(node, home: home)
        let isOn = Binding(
            get: { selected.contains(node.url) },
            set: { if $0 { selected.insert(node.url) } else { selected.remove(node.url) } })
        return HStack(spacing: 12) {
            Toggle("", isOn: isOn).labelsHidden().toggleStyle(.checkbox).disabled(!canTick).opacity(canTick ? 1 : 0.3)
            Image(nsImage: other ? NSWorkspace.shared.icon(for: .folder) : NSWorkspace.shared.icon(forFile: node.url.path))
                .resizable().frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text(other ? L("group.Other") : node.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                HStack(spacing: 8) {
                    if !other { SafetyBadge(safety: safety) }
                    if safeInside > 0 {
                        Text(String(format: L("map.safeInside"), formatBytes(safeInside)))
                            .font(.system(size: 11)).foregroundStyle(SafetyBadge.color(.safe))
                    }
                }
            }
            Spacer()
            Text(formatBytes(node.bytes)).font(.system(size: 15, weight: .medium)).monospacedDigit()
            Image(systemName: "chevron.forward").font(.system(size: 12, weight: .bold))
                .opacity(node.children.isEmpty || other ? 0 : 0.7)
        }
        .modifier(RowBackground(highlighted: isOn.wrappedValue))
        .contentShape(Rectangle())
        .onTapGesture { if !node.children.isEmpty && !other { open(node) } }
    }

    private func open(_ node: DiskNode) {
        trail.append(node)
        selected = []
    }

    private func scan() {
        scanning = true
        let home = home
        Task {
            if let root = try? await Task.detached(operation: { try await buildDiskTree(root: home, depth: 4) }).value {
                trail = [root]
            }
            selected = []
            scanning = false
        }
    }

    private func remove(_ items: [ScanItem]) {
        let cleaner = AppEnv.shared.cleaner
        Task { result = await Task.detached { await cleaner.clean(items, disposal: .trash) }.value }
    }
}

/// "Safe to delete" / "Review first" / "Do not delete" label.
struct SafetyBadge: View {
    let safety: Safety

    static func color(_ safety: Safety) -> Color {
        switch safety {
        case .safe: Color(hex: 0x3EE0A8)
        case .review: Theme.accent
        case .risky: Color(hex: 0xFF6B6B)
        }
    }

    var body: some View {
        Text(L("safety.\(safety)"))
            .font(.system(size: 11, weight: .bold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Self.color(safety).opacity(0.18)))
            .foregroundStyle(Self.color(safety))
    }
}

/// Largest entry as a big bubble in the middle, the rest around it. Area follows size.
private struct BubbleChart: View {
    let nodes: [DiskNode]
    let tint: Color
    let deep: Color
    let onOpen: (DiskNode) -> Void

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let center = nodes.first
            let rest = Array(nodes.dropFirst())
            let big = side * 0.22
            let maxBytes = Double(max(center?.bytes ?? 1, 1))
            ZStack {
                Circle().fill(RadialGradient(colors: [deep.opacity(0.45), .clear], center: .center, startRadius: 0, endRadius: side * 0.5))
                    .frame(width: side * 0.98, height: side * 0.98)
                if let center { bubble(center, radius: big) }
                ForEach(Array(rest.enumerated()), id: \.offset) { index, node in
                    let r = max(side * 0.06, min(big * 0.62, big * sqrt(Double(node.bytes) / maxBytes)))
                    let angle = -Double.pi / 2 + Double(index) * 2 * Double.pi / Double(max(rest.count, 1))
                    let distance = big + r + 10
                    bubble(node, radius: r)
                        .offset(x: cos(angle) * distance, y: sin(angle) * distance)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func bubble(_ node: DiskNode, radius: CGFloat) -> some View {
        Color.clear
            .glassEffect(.regular.tint(tint.opacity(0.30)), in: .circle)
            .overlay {
                VStack(spacing: 2) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: node.url.path))
                        .resizable().frame(width: radius * 0.6, height: radius * 0.6)
                    if radius > 48 {
                        Text(node.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Text(formatBytes(node.bytes)).font(.system(size: 11)).opacity(0.85)
                    }
                }
                .padding(6)
            }
            .frame(width: radius * 2, height: radius * 2)
            .help("\(node.name) — \(formatBytes(node.bytes))")
            .onTapGesture { onOpen(node) }
    }
}
