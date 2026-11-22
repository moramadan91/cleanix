import SwiftUI
import AppKit
import NaddafCore

/// Uninstall apps together with their leftover files. Everything goes to the Trash (restorable from there).
struct UninstallView: View {
    let section: AppSection

    private enum Phase { case intro, scanning, results, done }

    @State private var phase = Phase.intro
    @State private var apps: [AppInfo] = []
    @State private var selected: Set<String> = []
    @State private var search = ""
    @State private var preview: [ScanItem] = []
    @State private var showPreview = false
    @State private var result = CleanResult()

    private var remover: RemoverScanner { RemoverScanner(appDirs: AppEnv.shared.userAppDirs, home: AppEnv.shared.home) }
    private var shown: [AppInfo] {
        search.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        switch phase {
        case .intro: IntroHero(section: section) { load() }
        case .scanning: ScanningView()
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
                TextField(L("common.search"), text: $search).textFieldStyle(.roundedBorder).frame(width: 220)
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(shown, id: \.bundleID) { app in
                        let isOn = Binding(
                            get: { selected.contains(app.bundleID) },
                            set: { if $0 { selected.insert(app.bundleID) } else { selected.remove(app.bundleID) } })
                        HStack(spacing: 12) {
                            Toggle("", isOn: isOn).labelsHidden().toggleStyle(.checkbox)
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 32, height: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                                Text(app.vendor).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            if running.contains(app.bundleID) {
                                Text(L("caches.quitFirst")).font(.system(size: 12, weight: .semibold))
                                    .padding(.horizontal, 10).padding(.vertical, 4)
                                    .background(Capsule().fill(Theme.accent.opacity(0.22))).foregroundStyle(Theme.accent)
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
            ActionButton(title: L("apps.uninstall"), disabled: selected.isEmpty) { review() }
        }
        .padding(.horizontal, 40)
        .padding(.bottom, 28)
        .sheet(isPresented: $showPreview) {
            PreviewSheet(items: preview, disposal: .trash) { clean($0) }
        }
    }

    private func load() {
        phase = .scanning
        let remover = remover
        Task {
            apps = await Task.detached { await remover.apps() }.value.sorted { $0.bytes > $1.bytes }
            selected = []
            phase = .results
        }
    }

    /// The app bundle plus every leftover file, so the preview shows exactly what goes.
    private func review() {
        let remover = remover
        preview = apps.filter { selected.contains($0.bundleID) }.flatMap { app in
            [ScanItem(url: app.url, bytes: app.bytes, reason: "App", safety: .review, group: app.name)]
                + remover.leftovers(for: app)
        }
        showPreview = true
    }

    private func clean(_ items: [ScanItem]) {
        let cleaner = AppEnv.shared.cleaner
        Task {
            result = await Task.detached { await cleaner.clean(items, disposal: .trash) }.value
            phase = .done
        }
    }
}
