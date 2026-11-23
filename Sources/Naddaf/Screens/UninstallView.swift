import SwiftUI
import AppKit
import NaddafCore

/// Uninstall apps together with their leftover files. Everything goes to the Trash (restorable from there).
struct UninstallView: View {
    @Environment(\.screenStarted) private var screenStarted
    let section: AppSection

    private enum Phase { case intro, scanning, results, cleaning(CleaningRun), done }

    @State private var phase = Phase.intro
    @State private var apps: [AppInfo] = []
    @State private var selected: Set<String> = []
    @State private var search = ""
    /// Set together with opening the sheet, so the sheet gets the items with it (an isPresented sheet
    /// could be built before the items landed and stay empty).
    @State private var preview: PreviewBatch?
    @State private var result = CleanResult()
    @State private var reviewing = false

    private var remover: RemoverScanner { RemoverScanner(appDirs: AppEnv.shared.userAppDirs, home: AppEnv.shared.home) }
    @AppStorage(ListSort.key) private var sort = ListSort.largest
    private var shown: [AppInfo] {
        let found = search.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(search) }
        return sort.sorted(found, name: \.name, bytes: \.bytes)
    }

    var body: some View {
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
                    ForEach(shown, id: \.bundleID) { app in
                        let isOn = Binding(
                            get: { selected.contains(app.bundleID) },
                            set: { if $0 { selected.insert(app.bundleID) } else { selected.remove(app.bundleID) } })
                        HStack(spacing: 12) {
                            Toggle("", isOn: isOn).labelsHidden().toggleStyle(.glassCheck)
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 32, height: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                                Text(app.vendor).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            if running.contains(app.bundleID) {
                                Text(L("caches.quitFirst")).modifier(GlassBadge())
                            }
                            Spacer()
                            Text(formatBytes(app.bytes)).font(.system(size: 15, weight: .medium)).monospacedDigit()
                        }
                        .modifier(RowBackground(highlighted: isOn.wrappedValue))
                    }
                }
            }
            .scrollIndicators(.hidden)
                .glassPanel()
            ActionButton(title: reviewing ? L("common.scanning") : L("apps.uninstall"),
                         disabled: selected.isEmpty || reviewing) { review() }
        }
        .padding(.horizontal, 40)
        .padding(.bottom, 28)
        .sheet(item: $preview) { batch in
            PreviewSheet(section: section, items: batch.items, disposal: .trash) { clean($0) }
        }
    }

    private func load() {
        phase = .scanning
        screenStarted()
        let remover = remover
        Task {
            apps = await Task.detached { await remover.apps() }.value.sorted { $0.bytes > $1.bytes }
            selected = []
            phase = .results
        }
    }

    /// The app bundle plus every leftover file, so the preview shows exactly what goes.
    /// Leftovers are found off the main thread, all chosen apps at once, so the window never freezes.
    private func review() {
        reviewing = true
        let remover = remover
        let chosen = apps.filter { selected.contains($0.bundleID) }
        Task {
            let items = await Task.detached {
                await withTaskGroup(of: (Int, [ScanItem]).self) { group in
                    for (i, app) in chosen.enumerated() {
                        group.addTask {
                            (i, [ScanItem(url: app.url, bytes: app.bytes, reason: "App", safety: .review, group: app.name)]
                                + remover.leftovers(for: app))
                        }
                    }
                    var out = [[ScanItem]](repeating: [], count: chosen.count)
                    for await (i, list) in group { out[i] = list }
                    return out.flatMap { $0 }
                }
            }.value
            reviewing = false
            preview = PreviewBatch(items: items)
        }
    }

    struct PreviewBatch: Identifiable {
        let id = UUID()
        let items: [ScanItem]
    }

    private func clean(_ items: [ScanItem]) {
        let cleaner = AppEnv.shared.cleaner
        let run = CleaningRun(items: items)
        phase = .cleaning(run)
        Task {
            result = await run.clean(items, using: cleaner, disposal: .trash)
            phase = .done
        }
    }
}
