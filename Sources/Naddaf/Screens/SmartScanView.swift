import SwiftUI
import AppKit
import NaddafCore

/// One button for the safe stuff: system junk, app caches (apps that are not running) and browser caches.
/// Everything goes to Quarantine, so it can be undone for 30 days.
struct SmartScanView: View {
    @Environment(\.screenStarted) private var screenStarted
    let section: AppSection

    private enum Phase { case intro, scanning, results, done }

    @State private var phase = Phase.intro
    @State private var sections: [SmartScanSection] = []
    @State private var showPreview = false
    @State private var result = CleanResult()
    @State private var undoRecords: [QuarantineRecord] = []
    @State private var scanStart = Date()
    /// The scan itself takes a second; the lens gets this long so the search can be seen.

    private var allItems: [ScanItem] { sections.flatMap(\.items) }

    var body: some View {
        switch phase {
        case .intro: IntroHero(section: section) { scan() }
        case .scanning: LensScanView(section: section, started: scanStart,
                                       stages: ["smart.stage1", "smart.stage2", "smart.stage3", "smart.stage4"])
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
                    .depthGlass(RoundedRectangle(cornerRadius: 22), lift: 0.8)
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
        scanStart = .now
        phase = .scanning
        screenStarted()
        let env = AppEnv.shared
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let caches = AppCacheScanner(home: env.home, appDirs: env.appDirs, runningBundleIDs: { running })
        let privacy = PrivacyScanner(home: env.home)
        let sweep = SweepScanner(home: env.home)
        let smart = SmartScan(sections: [
            // Only `.safe` junk: backups and attachments never go in the one-button clean.
            ("tab.sweep", ClosureScanner { try await sweep.scan().filter { $0.safety == .safe } }),
            ("tab.appCaches", ClosureScanner {
                try await caches.groups().filter { !$0.isRunning && !$0.isSystem }.flatMap(\.items)
            }),
            // Browser caches only; history and cookies are never part of the one-button clean.
            ("smart.browser", ClosureScanner { try await privacy.scan().filter { $0.safety == .safe } }),
        ])
        Task {
            async let found = Task.detached { await smart.run() }.value
            try? await Task.sleep(for: .seconds(LensScanView.duration))
            sections = await found
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
    @State private var loading = false

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)
            if total > 0 {
                VStack(alignment: .leading, spacing: 10) {
                    Text(String(format: L("overview.used"), formatBytes(total - free), formatBytes(total)))
                        .font(.system(size: 20, weight: .semibold))
                    HStack(spacing: 12) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.10))
                                Capsule()
                                    .fill(LinearGradient(colors: [section.tint, Theme.accent], startPoint: .leading, endPoint: .trailing))
                                    .frame(width: geo.size.width * CGFloat(Double(total - free) / Double(total)))
                            }
                        }
                        .frame(height: 22)
                        // Reads the disk again; spins while it does, so the user sees it really refreshed.
                        Button { Task { await load() } } label: {
                            Image(systemName: "arrow.clockwise")
                                .rotationEffect(.degrees(loading ? 360 : 0))
                                .animation(loading ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: loading)
                        }
                        .buttonStyle(.liquid(small: true))
                        .disabled(loading)
                        .accessibilityLabel(L("overview.refresh"))
                    }
                    Text(String(format: L("overview.free"), formatBytes(free))).foregroundStyle(.secondary)
                }
                .padding(24)
                .depthGlass(RoundedRectangle(cornerRadius: 26))
            }
            HStack(spacing: 14) {
                ForEach(tiles, id: \.key) { tile in
                    VStack(spacing: 8) {
                        Text(L(tile.key)).font(.system(size: 15, weight: .semibold))
                        Text(formatBytes(tile.bytes)).font(.system(size: 22, weight: .bold)).monospacedDigit()
                    }
                    .frame(width: 170, height: 100)
                    .depthGlass(RoundedRectangle(cornerRadius: 22), lift: 0.8)
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
        loading = true
        let started = Date()
        defer { loading = false }
        let home = AppEnv.shared.home
        let values = try? home.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        total = Int64(values?.volumeTotalCapacity ?? 0)
        free = values?.volumeAvailableCapacityForImportantUsage ?? 0
        let places = [("tab.trash", ".Trash"), ("tab.downloads", "Downloads"),
                      ("tab.appCaches", "Library/Caches"), ("group.Logs", "Library/Logs")]
        // The four folders are sized at the same time (warm cache: ~0.58 s one by one, ~0.35 s together).
        let sizes = await withTaskGroup(of: (Int, Int64).self) { group in
            for (i, place) in places.enumerated() {
                group.addTask { (i, FS.size(of: home.appendingPathComponent(place.1))) }
            }
            var out = [Int64](repeating: 0, count: places.count)
            for await (i, bytes) in group { out[i] = bytes }
            return out
        }
        tiles = zip(places, sizes).map { (key: $0.0.0, bytes: $0.1) }
        // Keep the spin visible a moment: a refresh that finishes in 0.3 s looks like nothing happened.
        let left = 0.6 - Date().timeIntervalSince(started)
        if left > 0 { try? await Task.sleep(for: .seconds(left)) }
    }
}

/// Smart Scan's search: a liquid-glass lens sweeps over the section orb while a line says what is
/// being checked. It only animates during the scan, so idle CPU is untouched.
struct LensScanView: View {
    let section: AppSection
    let started: Date
    /// Localization keys, shown one after another over the scan.
    var stages = ["scan.stage1", "scan.stage2", "scan.stage3", "scan.stage4"]
    static let duration = 6.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let t = max(0, context.date.timeIntervalSince(started))
            let progress = min(1, t / Self.duration)
            VStack(spacing: 28) {
                Spacer(minLength: 0)
                ZStack {
                    Circle().strokeBorder(.white.opacity(0.10), lineWidth: 1).frame(width: 290, height: 290)
                    // Radar sweep around the orb.
                    Circle()
                        .trim(from: 0, to: 0.22)
                        .stroke(AngularGradient(colors: [.clear, .white.opacity(0.55)], center: .center,
                                                startAngle: .zero, endAngle: .degrees(80)),
                                style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .frame(width: 290, height: 290)
                        .rotationEffect(.degrees(t * 120))
                    Image(systemName: section.symbol)
                        .font(.system(size: 70, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: 180, height: 180)
                        .depthGlass(Circle(), lift: 1.2)
                    lens.offset(lensOffset(t))
                }
                .frame(height: 310)
                .accessibilityHidden(true)

                VStack(spacing: 12) {
                    Text(L(stages[min(stages.count - 1, Int(progress * Double(stages.count)))]))
                        .font(.system(size: 17, weight: .semibold))
                        .contentTransition(.opacity)
                        .animation(.easeInOut(duration: 0.3), value: Int(progress * Double(stages.count)))
                    Capsule()
                        .fill(.white.opacity(0.10))
                        .frame(width: 260, height: 6)
                        .overlay(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.85)).frame(width: 260 * progress, height: 6)
                        }
                        .environment(\.layoutDirection, Lang.direction)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// A glass loupe with a handle; the glass bends the orb and background under it.
    private var lens: some View {
        ZStack(alignment: .bottomTrailing) {
            Capsule()
                .fill(LinearGradient(colors: [.white.opacity(0.75), .white.opacity(0.35)], startPoint: .top, endPoint: .bottom))
                .frame(width: 12, height: 48)
                .rotationEffect(.degrees(-45))
                .offset(x: 30, y: 30)
            Color.clear
                .frame(width: 96, height: 96)
                .depthGlass(Circle(), lift: 1.6)
                .overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: 3))
        }
        .frame(width: 96, height: 96)
    }

    /// Wandering figure-of-eight path, so the lens looks like it is searching, not orbiting.
    private func lensOffset(_ t: Double) -> CGSize {
        CGSize(width: 105 * sin(t * 1.3), height: 60 * sin(t * 2.1 + 0.6))
    }
}
