import SwiftUI
import QuickLook
import AppKit
import NaddafCore
import UniformTypeIdentifiers

/// Disk Map: a list of what is in the current folder (with a safety label on each entry)
/// next to a simple bubble view where size = area. Click to open a folder; tick and remove
/// what is safe or reviewed. Entries marked "do not delete" cannot be ticked.
struct DiskMapView: View {
    @Environment(\.screenStarted) private var screenStarted
    let section: AppSection

    @State private var trail: [DiskNode] = []
    @State private var scanning = false
    @State private var selected: [URL: ScanItem] = [:]
    @State private var levels: [URL: Level] = [:]
    @State private var icons: [UTType: NSImage] = [:]
    /// Item shown in the Quick Look panel (right-click a row).
    @State private var quickLook: URL?
    @State private var showPreview = false
    @State private var cleaning: CleaningRun?
    @State private var result: CleanResult?

    private struct RowInfo {
        let selectionURL: URL
        let safety: Safety
        let safeBytes: Int64
        let icon: NSImage
    }

    private struct Level {
        let rows: [URL: RowInfo]
        let safeBytes: Int64
    }

    private var home: URL { AppEnv.shared.home }

    var body: some View {
        if let cleaning {
            CleaningView(run: cleaning)
        } else if let result {
            DoneView(result: result) { self.result = nil }
        } else if scanning {
            ScanningView()
        } else if let current = trail.last, let level = levels[current.url] {
            content(current, level: level)
        } else {
            IntroHero(section: section) { scan() }
        }
    }

    private func entries(_ node: DiskNode) -> [DiskNode] {
        // "Other" folds tiny entries and points at the parent folder: never offer it for removal.
        node.children.filter { $0.bytes > 0 }
    }

    private func isOther(_ node: DiskNode, in parent: DiskNode) -> Bool { node.url == parent.url }

    private func content(_ current: DiskNode, level: Level) -> some View {
        let list = entries(current)
        return VStack(spacing: 14) {
            header(current)
            HStack(alignment: .top, spacing: 28) {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(list, id: \.url) { node in
                            if let info = level.rows[node.url] { row(node, parent: current, info: info) }
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .quickLookPreview($quickLook)
                .glassPanel()
                .frame(maxWidth: .infinity)

                BubbleChart(nodes: Array(list.prefix(8)), tint: section.tint, deep: section.tint2,
                            icon: { level.rows[$0]?.icon }) { node in
                    if !node.children.isEmpty && !isOther(node, in: current) { open(node) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(current.name): \(formatBytes(current.bytes))").font(.system(size: 15, weight: .semibold))
                    if level.safeBytes > 0 {
                        Text(String(format: L("map.safeInside"), formatBytes(level.safeBytes)))
                            .font(.system(size: 13)).foregroundStyle(SafetyBadge.color(.safe))
                    }
                }
                Spacer()
                Text(String(format: L("map.selection"),
                            selected.count.formatted(.number.locale(Lang.locale)),
                            formatBytes(selected.values.reduce(0) { $0 + $1.bytes })))
                    .monospacedDigit()
                Button(L("map.clearSelection")) { selected.removeAll() }
                    .buttonStyle(.liquid())
                    .disabled(selected.isEmpty)
                Button(L("map.remove")) { showPreview = true }
                    .buttonStyle(.liquid(prominent: true))
                    .disabled(selected.isEmpty)
            }
        }
        .padding(.horizontal, 40)
        .padding(.top, 14)
        .padding(.bottom, 24)
        .sheet(isPresented: $showPreview) {
            let items = selected.values.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
            PreviewSheet(section: section, items: items, disposal: .trash, showsPaths: true) { remove($0) }
        }
    }

    private func header(_ current: DiskNode) -> some View {
        HStack(spacing: 10) {
            Button { trail.removeLast() } label: {
                Image(systemName: "chevron.backward").font(.system(size: 14, weight: .bold)).frame(width: 30, height: 30)
            }
            .buttonStyle(.liquid())
            .disabled(trail.count < 2)
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(Array(trail.enumerated()), id: \.offset) { index, node in
                        if index > 0 { Image(systemName: "chevron.forward").font(.caption).foregroundStyle(.secondary) }
                        Button(index == 0 ? "~" : node.name) { trail = Array(trail.prefix(index + 1)) }
                            .buttonStyle(.plain)
                            .font(.system(size: 15, weight: index == trail.count - 1 ? .bold : .regular))
                    }
                }
            }
            .scrollIndicators(.hidden)
            Button(L("common.reveal")) { revealInFinder(current.url) }.buttonStyle(.liquid())
        }
    }

    private func row(_ node: DiskNode, parent: DiskNode, info: RowInfo) -> some View {
        let other = isOther(node, in: parent)
        let url = info.selectionURL
        let safety = info.safety
        let inherited = selected.keys.contains { ancestor in
            (other && ancestor == url) || isDescendant(url, of: ancestor)
        }
        let canTick = !inherited && !other && safety != .risky
        let safeInside = safety == .safe ? 0 : info.safeBytes
        let isOn = Binding(
            get: { inherited || selected[url] != nil },
            set: { on in
                guard canTick else { return }
                if on {
                    guard selectionURL(node.url) == url,
                          !selected.keys.contains(where: { isDescendant(url, of: $0) }) else { return }
                    selected = selected.filter { !isDescendant($0.key, of: url) }
                    // Use the resolved key for selection and the scanned path for removal.
                    selected[url] = ScanItem(url: node.url, bytes: node.bytes, reason: "Disk Map",
                                             safety: safety, group: parent.name)
                } else {
                    selected.removeValue(forKey: url)
                }
            })
        return HStack(spacing: 12) {
            Toggle(other ? L("group.Other") : node.name, isOn: isOn)
                .labelsHidden().toggleStyle(.glassCheck).disabled(!canTick)
                .opacity(canTick || inherited ? 1 : 0.3)
            Image(nsImage: info.icon)
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
        .contextMenu {
            if !other {
                Button(L("common.quickLook"), systemImage: "eye") { quickLook = node.url }
                Button(L("common.reveal"), systemImage: "folder") { revealInFinder(node.url) }
            }
        }
    }

    private func open(_ node: DiskNode) {
        prepareLevel(node)
        trail.append(node)
    }

    private func prepareLevel(_ parent: DiskNode) {
        guard levels[parent.url] == nil else { return }
        var rows: [URL: RowInfo] = [:]
        for node in entries(parent) {
            let other = isOther(node, in: parent)
            let safety = other ? Safety.review : SpaceAdvice.safety(of: node.url, home: home)
            let type = other ? .folder : (try? node.url.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? .data
            let icon = icons[type] ?? NSWorkspace.shared.icon(for: type)
            icons[type] = icon
            let safeBytes = safety == .safe ? node.bytes : SpaceAdvice.safeBytes(node, home: home)
            rows[node.url] = RowInfo(selectionURL: selectionURL(node.url), safety: safety,
                                     safeBytes: safeBytes, icon: icon)
        }
        let safeBytes = SpaceAdvice.safety(of: parent.url, home: home) == .safe
            ? parent.bytes : rows.values.reduce(0) { $0 + $1.safeBytes }
        levels[parent.url] = Level(rows: rows, safeBytes: safeBytes)
    }

    private func selectionURL(_ url: URL) -> URL {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return URL(fileURLWithPath: path, isDirectory: false)
    }

    // Selection URLs have already been resolved and standardized.
    private func isDescendant(_ url: URL, of ancestor: URL) -> Bool {
        let path = url.pathComponents
        let prefix = ancestor.pathComponents
        return path.count > prefix.count && path.starts(with: prefix)
    }

    private func rebaseSelection(on root: DiskNode) {
        let rootPath = root.url.pathComponents
        selected = selected.reduce(into: [:]) { refreshed, pair in
            let (url, item) = pair
            guard FileManager.default.fileExists(atPath: item.url.path), selectionURL(item.url) == url else { return }
            refreshed[url] = item
            let path = item.url.pathComponents
            guard path.starts(with: rootPath) else { return }
            var node = root
            for component in path.dropFirst(rootPath.count) {
                guard let child = node.children.first(where: {
                    $0.url.lastPathComponent == component && !isOther($0, in: node)
                }) else { return }
                node = child
            }
            refreshed[url] = ScanItem(url: node.url, bytes: node.bytes, reason: item.reason,
                                      safety: item.safety, group: item.group)
        }
    }

    private func scan() {
        scanning = true
        screenStarted()
        let home = home
        let currentPath = trail.dropFirst().map(\.url)
        var keepingVisible = Set(currentPath)
        for item in selected.values {
            var url = item.url
            while url.pathComponents.count > home.pathComponents.count {
                keepingVisible.insert(url)
                url.deleteLastPathComponent()
            }
        }
        Task {
            defer { scanning = false }
            guard let root = try? await Task.detached(operation: { [keepingVisible] in
                try await buildDiskTree(root: home, depth: 4, keepingVisible: keepingVisible)
            }).value else { return }

            var refreshed = [root]
            for url in currentPath {
                guard let parent = refreshed.last,
                      let child = parent.children.first(where: { $0.url == url && !isOther($0, in: parent) })
                else { break }
                refreshed.append(child)
            }
            rebaseSelection(on: root)
            levels.removeAll()
            for node in refreshed { prepareLevel(node) }
            trail = refreshed
        }
    }

    private func remove(_ items: [ScanItem]) {
        let cleaner = AppEnv.shared.cleaner
        let run = CleaningRun(items: items)
        cleaning = run
        Task {
            let outcome = await run.clean(items, using: cleaner, disposal: .trash)
            if outcome.failed.isEmpty {
                selected.removeAll()
            } else {
                let removed = Set(outcome.removed)
                selected = selected.filter { !removed.contains($0.value.url) }
            }
            if !outcome.removed.isEmpty { scan() }
            result = outcome
            cleaning = nil
        }
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
    let icon: (URL) -> NSImage?
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
                    if let image = icon(node.url) {
                        Image(nsImage: image).resizable().frame(width: radius * 0.6, height: radius * 0.6)
                    }
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
