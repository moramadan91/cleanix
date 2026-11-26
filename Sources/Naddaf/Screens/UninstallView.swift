import SwiftUI
import AppKit
import NaddafCore

/// Uninstall apps together with their leftover files. Everything goes to the Trash (restorable from there).
struct UninstallView: View {
    @Environment(\.screenStarted) private var screenStarted
    @Environment(\.screenIsVisible) private var isVisible
    let section: AppSection

    private enum Phase { case intro, scanning, results, cleaning(CleaningRun), done }

    private struct AppFiles {
        let items: [ScanItem]
        let total: Int64

        init(bundle: ScanItem, leftovers: [ScanItem]) {
            items = ([bundle] + leftovers).sorted { $0.bytes > $1.bytes }
            total = items.reduce(0) { $0 + $1.bytes }
        }
    }

    @State private var phase = Phase.intro
    @State private var apps: [AppInfo] = []
    @State private var files: [URL: AppFiles] = [:]
    @State private var selected: Set<URL> = []
    @State private var expanded: Set<URL> = []
    @State private var scanID: UUID?
    @State private var search = ""
    /// Set together with opening the sheet, so the sheet gets the items with it (an isPresented sheet
    /// could be built before the items landed and stay empty).
    @State private var preview: PreviewBatch?
    @State private var result = CleanResult()

    private var remover: RemoverScanner { RemoverScanner(appDirs: AppEnv.shared.userAppDirs, home: AppEnv.shared.home) }
    @AppStorage(ListSort.key) private var sort = ListSort.largest
    private var shown: [AppInfo] {
        let found = search.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(search) }
        return sort.sorted(found, name: \.name, bytes: { files[$0.url]?.total ?? $0.bytes })
    }

    var body: some View {
        content.task(id: scanID) {
            if scanID != nil { await findAppsAndFiles() }
        }
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .intro: IntroHero(section: section) { load() }
        case .scanning: ScanningView()
        case .cleaning(let run): CleaningView(run: run)
        case .done: DoneView(result: result) { load() }
        case .results: results
        }
    }

    private var results: some View {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return VStack(spacing: 14) {
            HStack(spacing: 12) {
                Text(String(format: L("apps.selected"), selected.count)).font(.system(size: 16, weight: .semibold))
                Spacer()
                SortMenu(sort: $sort)
                TextField(L("common.search"), text: $search).glassField().frame(width: 160)
            }
            .padding(.horizontal, 6)
            .padding(.top, 12) // clear of the tabs above
            .frame(maxWidth: 760)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(shown, id: \.url) { app in
                        row(app, running: running.contains(app.bundleID))
                    }
                }
            }
            .scrollIndicators(.hidden)
                .glassPanel()
            let waitingForFiles = selected.contains { files[$0] == nil }
            ActionButton(title: waitingForFiles ? L("common.scanning") : L("apps.uninstall"),
                         disabled: selected.isEmpty || waitingForFiles) { review() }
        }
        .padding(.horizontal, 40)
        .padding(.bottom, 28)
        .sheet(item: $preview) { batch in
            PreviewSheet(section: section, items: batch.items, disposal: .trash) { clean($0) }
        }
    }

    private func row(_ app: AppInfo, running: Bool) -> some View {
        let isOn = Binding(
            get: { selected.contains(app.url) },
            set: { if $0 { selected.insert(app.url) } else { selected.remove(app.url) } })
        let isExpanded = expanded.contains(app.url)
        let appFiles = files[app.url]
        let disclosureTitle = isExpanded ? L("apps.hideFiles") : L("apps.showFiles")
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Toggle(app.name, isOn: isOn).labelsHidden().toggleStyle(.glassCheck)
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text(app.vendor).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                if running { Text(L("caches.quitFirst")).modifier(GlassBadge()) }
                Spacer()
                if appFiles == nil && isVisible {
                    ProgressView().controlSize(.small).accessibilityLabel(L("common.scanning"))
                }
                Text(formatBytes(appFiles?.total ?? app.bytes)).font(.system(size: 15, weight: .medium)).monospacedDigit()
                Button {
                    if isExpanded { expanded.remove(app.url) } else { expanded.insert(app.url) }
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.forward")
                        .frame(width: 16)
                }
                .buttonStyle(.liquid(small: true))
                .accessibilityLabel(disclosureTitle)
                .help(disclosureTitle)
            }
            if isExpanded {
                ForEach(appFiles?.items ?? [bundleItem(app)]) { item in
                    HStack(spacing: 12) {
                        Text(displayPath(item.url)).lineLimit(1).truncationMode(.middle)
                            .help(displayPath(item.url))
                        Spacer()
                        Text(formatBytes(item.bytes)).monospacedDigit()
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 28)
                }
            }
        }
        .modifier(RowBackground(highlighted: isOn.wrappedValue))
    }

    private func load() {
        phase = .scanning
        screenStarted()
        files = [:]
        selected = []
        expanded = []
        scanID = UUID()
    }

    private func findAppsAndFiles() async {
        let remover = remover
        let found = await remover.apps()
        guard !Task.isCancelled else { return }
        apps = found
        phase = .results
        let bundles = Dictionary(uniqueKeysWithValues: found.map { ($0.url, bundleItem($0)) })
        await remover.scanLeftovers(for: found) { @MainActor url, leftovers in
            guard !Task.isCancelled, let bundle = bundles[url] else { return }
            files[url] = AppFiles(bundle: bundle, leftovers: leftovers)
        }
    }

    private func bundleItem(_ app: AppInfo) -> ScanItem {
        ScanItem(url: app.url, bytes: app.bytes, reason: "App", safety: .review, group: app.name)
    }

    private func review() {
        // Another kept copy with the same bundle ID (e.g. a beta) shares these Library files: keep them.
        let keptIDs = Set(apps.filter { !selected.contains($0.url) }.map(\.bundleID))
        let items = apps.filter { selected.contains($0.url) }.flatMap { app in
            let all = files[app.url]?.items ?? []
            return keptIDs.contains(app.bundleID) ? all.filter { $0.url == app.url } : all
        }
        preview = PreviewBatch(items: RemoverScanner.withoutNestedPaths(items, url: \.url))
    }

    struct PreviewBatch: Identifiable {
        let id = UUID()
        let items: [ScanItem]
    }

    private func clean(_ items: [ScanItem]) {
        scanID = nil
        let cleaner = AppEnv.shared.uninstallCleaner(for: items)
        let run = CleaningRun(items: items)
        phase = .cleaning(run)
        Task {
            result = await run.clean(items, using: cleaner, disposal: .trash)
            phase = .done
        }
    }
}
