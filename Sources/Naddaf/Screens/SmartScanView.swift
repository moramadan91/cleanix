import SwiftUI
import AppKit
import NaddafCore

/// One button for the safe stuff: system junk, app caches (apps that are not running) and browser caches.
/// Everything goes to Quarantine, so it can be undone for 30 days.
struct SmartScanView: View {
    let section: AppSection

    private enum Phase { case intro, scanning, results, done }

    @State private var phase = Phase.intro
    @State private var sections: [SmartScanSection] = []
    @State private var showPreview = false
    @State private var result = CleanResult()
    @State private var undoRecords: [QuarantineRecord] = []

    private var allItems: [ScanItem] { sections.flatMap(\.items) }

    var body: some View {
        switch phase {
        case .intro: IntroHero(section: section) { scan() }
        case .scanning: ScanningView()
        case .done:
            DoneView(result: result, undoable: !undoRecords.isEmpty,
                     onUndo: undoRecords.isEmpty ? nil : { undo() }, onRescan: { scan() })
        case .results: results
        }
    }

    private var results: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 0)
            Text(formatBytes(allItems.reduce(0) { $0 + $1.bytes })).font(.system(size: 56, weight: .bold)).monospacedDigit()
            Text(L("smart.found")).foregroundStyle(.secondary)
            HStack(spacing: 14) {
                ForEach(sections, id: \.name) { s in
                    VStack(spacing: 8) {
                        Text(L(s.name)).font(.system(size: 15, weight: .semibold))
                        Text(formatBytes(s.bytes)).font(.system(size: 22, weight: .bold)).monospacedDigit()
                        Text(String(format: L("smart.items"), s.items.count)).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .frame(width: 180, height: 120)
                    .glassEffect(.regular.tint(section.tint.opacity(0.25)), in: .rect(cornerRadius: 22))
                }
            }
            Spacer(minLength: 0)
            ActionButton(title: L("smart.review"), disabled: allItems.isEmpty) { showPreview = true }
        }
        .padding(.horizontal, 40)
        .padding(.bottom, 28)
        .sheet(isPresented: $showPreview) {
            PreviewSheet(section: section, items: allItems, disposal: .quarantine) { clean($0) }
        }
    }

    private func scan() {
        phase = .scanning
        let env = AppEnv.shared
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let caches = AppCacheScanner(home: env.home, appDirs: env.appDirs, runningBundleIDs: { running })
        let privacy = PrivacyScanner(home: env.home)
        let smart = SmartScan(sections: [
            ("tab.sweep", SweepScanner(home: env.home)),
            ("tab.appCaches", ClosureScanner {
                try await caches.groups().filter { !$0.isRunning && !$0.isSystem }.flatMap(\.items)
            }),
            // Browser caches only; history and cookies are never part of the one-button clean.
            ("smart.browser", ClosureScanner { try await privacy.scan().filter { $0.safety == .safe } }),
        ])
        Task {
            sections = await Task.detached { await smart.run() }.value
            UserDefaults.standard.set(sections.reduce(0) { $0 + $1.bytes }, forKey: "lastSmartScanBytes")
            phase = .results
        }
    }

    private func clean(_ items: [ScanItem]) {
        let env = AppEnv.shared
        let start = Date()
        Task {
            let r = await Task.detached { await env.cleaner.clean(items, disposal: .quarantine) }.value
            let removed = Set(r.removed)
            undoRecords = env.quarantine.records().filter { $0.date >= start && removed.contains($0.original) }
            result = r
            phase = .done
        }
    }

    private func undo() {
        for record in undoRecords { try? AppEnv.shared.quarantine.restore(record) }
        undoRecords = []
        scan()
    }
}

/// Storage at a glance plus the biggest easy wins. Read-only: cleaning happens in the other sections.
struct OverviewView: View {
    let section: AppSection

    @State private var total: Int64 = 0
    @State private var free: Int64 = 0
    @State private var tiles: [(key: String, bytes: Int64)] = []

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)
            if total > 0 {
                VStack(alignment: .leading, spacing: 10) {
                    Text(String(format: L("overview.used"), formatBytes(total - free), formatBytes(total)))
                        .font(.system(size: 20, weight: .semibold))
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.10))
                            Capsule()
                                .fill(LinearGradient(colors: [section.tint, Theme.accent], startPoint: .leading, endPoint: .trailing))
                                .frame(width: geo.size.width * CGFloat(Double(total - free) / Double(total)))
                        }
                    }
                    .frame(height: 22)
                    Text(String(format: L("overview.free"), formatBytes(free))).foregroundStyle(.secondary)
                }
                .padding(24)
                .glassEffect(.regular.tint(section.tint.opacity(0.18)), in: .rect(cornerRadius: 26))
            }
            HStack(spacing: 14) {
                ForEach(tiles, id: \.key) { tile in
                    VStack(spacing: 8) {
                        Text(L(tile.key)).font(.system(size: 15, weight: .semibold))
                        Text(formatBytes(tile.bytes)).font(.system(size: 22, weight: .bold)).monospacedDigit()
                    }
                    .frame(width: 170, height: 100)
                    .glassEffect(.regular.tint(section.tint.opacity(0.22)), in: .rect(cornerRadius: 22))
                }
            }
            if let last = UserDefaults.standard.object(forKey: "lastSmartScanBytes") as? Int64, last > 0 {
                Text(String(format: L("overview.lastSmart"), formatBytes(last))).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 40)
        .padding(.bottom, 28)
        .task { await load() }
    }

    private func load() async {
        let home = AppEnv.shared.home
        let values = try? home.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        total = Int64(values?.volumeTotalCapacity ?? 0)
        free = values?.volumeAvailableCapacityForImportantUsage ?? 0
        let places = [("tab.trash", ".Trash"), ("tab.downloads", "Downloads"),
                      ("tab.appCaches", "Library/Caches"), ("group.Logs", "Library/Logs")]
        tiles = await Task.detached {
            places.map { (key: $0.0, bytes: FS.size(of: home.appendingPathComponent($0.1))) }
        }.value
    }
}
