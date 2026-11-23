import SwiftUI
import AppKit
import NaddafCore

struct AppResetView: View {
    @Environment(\.screenStarted) private var screenStarted
    let section: AppSection

    private enum Phase { case intro, working, results, cleaning(CleaningRun), done }

    private struct PreviewBatch: Identifiable {
        let id = UUID()
        let app: AppInfo
        let items: [ScanItem]
    }

    @State private var phase = Phase.intro
    @State private var apps: [AppInfo] = []
    @State private var selected: AppInfo?
    @State private var running: Set<String> = []
    @State private var search = ""
    @State private var reviewing = false
    @State private var nothingToReset = false
    @State private var preview: PreviewBatch?
    @State private var result = CleanResult()
    @State private var undoRecords: [QuarantineRecord] = []
    @AppStorage(ListSort.key) private var sort = ListSort.largest

    private var remover: RemoverScanner {
        let env = AppEnv.shared
        return RemoverScanner(appDirs: env.userAppDirs, home: env.home)
    }

    private var shown: [AppInfo] {
        let found = search.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(search) }
        return sort.sorted(found, name: \.name, bytes: \.bytes)
    }

    var body: some View {
        switch phase {
        case .intro: IntroHero(section: section, title: L("reset.chooseApp")) { load() }
        case .working: ScanningView()
        case .cleaning(let run): CleaningView(run: run)
        case .done:
            DoneView(result: result, undoable: !undoRecords.isEmpty,
                     onUndo: undoRecords.isEmpty ? nil : { undo() }, onRescan: { load() })
        case .results: results
        }
    }

    private var results: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Text(L("reset.chooseApp")).font(.system(size: 16, weight: .semibold))
                Spacer()
                SortMenu(sort: $sort)
                TextField(L("common.search"), text: $search).glassField().frame(width: 160)
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: 760)

            if shown.isEmpty {
                Text(L("common.nothing")).foregroundStyle(.secondary).frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(shown, id: \.url) { row($0) }
                    }
                }
                .scrollIndicators(.hidden)
                .glassPanel()
                .frame(maxHeight: .infinity, alignment: .top)
            }

            if nothingToReset {
                Text(L("reset.nothing")).foregroundStyle(.secondary)
            }
            ActionButton(title: reviewing ? L("common.scanning") : L("tab.reset"),
                         disabled: selected == nil || reviewing) { review() }
        }
        .padding(.horizontal, 40)
        .padding(.top, 12)
        .padding(.bottom, 28)
        .onReceive(NSWorkspace.shared.publisher(for: \.runningApplications)) { _ in
            refreshRunningApps()
        }
        .sheet(item: $preview) { batch in
            PreviewSheet(section: section, items: batch.items, disposal: .quarantine) { clean($0, for: batch.app) }
        }
    }

    private func row(_ app: AppInfo) -> some View {
        let isRunning = running.contains(app.bundleID)
        let isSelected = Binding(
            get: { selected?.url == app.url },
            set: { on in
                refreshRunningApps()
                guard !running.contains(app.bundleID) else { return }
                selected = on ? app : nil
                nothingToReset = false
            }
        )
        return HStack(spacing: 12) {
            Toggle("", isOn: isSelected).labelsHidden().toggleStyle(.glassCheck)
                .accessibilityLabel(app.name).disabled(isRunning || reviewing)
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text(app.vendor).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            if isRunning {
                Text(L("caches.quitFirst")).modifier(GlassBadge())
            }
            Spacer()
            Text(formatBytes(app.bytes)).font(.system(size: 15, weight: .medium)).monospacedDigit()
        }
        .modifier(RowBackground(highlighted: isSelected.wrappedValue))
    }

    private func refreshRunningApps() {
        running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        if let selected, running.contains(selected.bundleID) {
            self.selected = nil
            nothingToReset = false
        }
    }

    private func load() {
        phase = .working
        screenStarted()
        let remover = remover
        Task {
            apps = await remover.apps()
            selected = nil
            nothingToReset = false
            refreshRunningApps()
            phase = .results
        }
    }

    private func review() {
        refreshRunningApps()
        guard let app = selected else { return }
        reviewing = true
        nothingToReset = false
        let remover = remover
        Task {
            let items = await Task.detached { remover.resetItems(for: app) }.value
            reviewing = false
            refreshRunningApps()
            guard selected == app else { return }
            if items.isEmpty {
                nothingToReset = true
            } else {
                preview = PreviewBatch(app: app, items: items)
            }
        }
    }

    private func clean(_ items: [ScanItem], for app: AppInfo) {
        refreshRunningApps()
        guard !running.contains(app.bundleID) else { return }
        let env = AppEnv.shared
        let start = Date()
        let run = CleaningRun(items: items)
        phase = .cleaning(run)
        Task {
            result = await run.clean(items, using: env.cleaner, disposal: .quarantine)
            let removed = Set(result.removed)
            undoRecords = env.quarantine.records().filter { $0.date >= start && removed.contains($0.original) }
            phase = .done
        }
    }

    private func undo() {
        for record in undoRecords { try? AppEnv.shared.quarantine.restore(record) }
        undoRecords = []
        load()
    }
}
