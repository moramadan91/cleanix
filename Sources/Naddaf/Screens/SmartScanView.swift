import SwiftUI
import AppKit
import NaddafCore

/// One button for the safe stuff: system junk, app caches (apps that are not running) and browser caches.
/// Everything goes to Quarantine, so it can be undone for 30 days.
struct SmartScanView: View {
    @Environment(\.screenStarted) private var screenStarted
    let section: AppSection

    private enum Phase { case intro, scanning, results, cleaning(CleaningRun), done }

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
        case .cleaning(let run): CleaningView(run: run)
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
        let smart = makeSmartScan(includeBrowserCaches: true)
        Task {
            async let found = Task.detached { await smart.run() }.value
            try? await Task.sleep(for: .seconds(LensScanView.duration))
            sections = await found
            UserDefaults.standard.set(sections.reduce(0) { $0 + $1.bytes }, forKey: "lastSmartScanBytes")
            UserDefaults.standard.set(Date(), forKey: "lastSmartScanDate")
            phase = .results
        }
    }

    private func clean(_ items: [ScanItem]) {
        let env = AppEnv.shared
        let start = Date()
        let run = CleaningRun(items: items)
        phase = .cleaning(run)
        Task {
            let r = await run.clean(items, using: env.cleaner, disposal: .quarantine)
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

/// Health, storage, and shortcuts to the tools that can help.
struct OverviewView: View {
    @Environment(\.screenIsVisible) private var isVisible
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openSection) private var openSection
    let section: AppSection
    let loginItems: LoginItemsReader

    @State private var volumeName: String?
    @State private var total: Int64 = 0
    @State private var free: Int64 = 0
    @State private var tiles: [(key: String, symbol: String, bytes: Int64)] = []
    @State private var loading = false
    @State private var refresh = 0
    @State private var health: HealthScore?
    @State private var battery: BatteryHealth?
    /// Health re-check: a quick Smart Scan so the score sees what cleaning changed.
    @State private var checking = false
    @State private var previousScore: Int?
    @AppStorage("lastSmartScanBytes") private var lastScanBytes = 0

    var body: some View {
        ScrollView {
            // Compact so the whole page fits the window without scrolling.
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 16) {
                    healthPanel
                    diskPanel
                        .containerRelativeFrame(.horizontal) { width, _ in max(250, (width - 18) / 3.15) }
                }
                // Both panels as tall as the taller one.
                .fixedSize(horizontal: false, vertical: true)
                statTiles
                recommendationsPanel
                AlertToggles(horizontal: true)
                    .frame(maxWidth: .infinity)
                if lastScanBytes > 0 {
                    Text(String(format: L("overview.lastSmart"), formatBytes(Int64(lastScanBytes))))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 20)
            .padding(.bottom, 10)
        }
        .frame(maxWidth: 900)
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity)
        .task(id: isVisible ? refresh : nil) { if isVisible { await load() } }
    }

    private var healthPanel: some View {
        HStack(alignment: .top, spacing: 18) {
            if let health {
                scoreRing(fraction: Double(health.score) / 100,
                          value: health.score.formatted(.number.locale(Lang.locale)),
                          label: L("health.title"))
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Text(health.map { L($0.score >= 80 ? "health.good" : $0.score >= 50 ? "health.fair" : "health.poor") }
                         ?? L("health.title"))
                        .font(.system(size: 17, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    refreshButton(title: L("health.recheck"), active: checking) {
                        Task { await recheck() }
                    }
                    .disabled(loading)
                }
                if let health {
                    ForEach(health.issues, id: \.self) { issue in
                        if let (section, tab) = issueDestination(issue) {
                            tipRow(L(issue), section: section, tab: tab)
                        }
                    }
                }
                // Small and a little lower, so it does not dominate the card.
                QuickBoostControls()
                    .frame(width: 190)
                    .padding(.top, 14)
                if checking {
                    Text(L("health.checking"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(section.tint)
                } else if let health, let previousScore {
                    let now = health.score.formatted(.number.locale(Lang.locale))
                    Text(previousScore == health.score ? String(format: L("health.same"), now)
                         : String(format: L("health.change"), previousScore.formatted(.number.locale(Lang.locale)), now))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(section.tint)
                }
            }
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .top)
        .depthGlass(RoundedRectangle(cornerRadius: 22))
    }

    private var diskPanel: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                Text(volumeName ?? L("overview.disk"))
                    .font(.system(size: 17, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                    .frame(maxWidth: .infinity, alignment: .leading)
                refreshButton(title: L("overview.refresh"), active: loading && !checking) { refresh += 1 }
                    .disabled(loading || checking)
            }
            if total > 0 {
                let used = Double(total - free) / Double(total)
                scoreRing(fraction: used, value: formatPercent(used), label: L("overview.diskUsage"))
                Text(String(format: L("overview.free"), formatBytes(free), formatBytes(total)))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text(L("overview.unknown")).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .top)
        .depthGlass(RoundedRectangle(cornerRadius: 22))
    }

    private var statTiles: some View {
        HStack(spacing: 14) {
            ForEach(tiles, id: \.key) { tile in
                overviewTile(title: L(tile.key), symbol: tile.symbol, value: formatBytes(tile.bytes))
            }
            if let battery {
                overviewTile(title: L("overview.battery"), symbol: batterySymbol(for: battery.percent),
                             value: formatPercent(Double(battery.percent) / 100),
                             detail: String(format: L("overview.batteryCycles"),
                                            battery.cycles.formatted(.number.locale(Lang.locale))))
            }
        }
    }

    private var recommendationsPanel: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(L("overview.tips"))
                .font(.system(size: 15, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 2)
            tipRow(L("overview.tipJunk"), section: .cleanup, tab: .sweep)
            if let trash = tiles.first(where: { $0.key == "tab.trash" }), trash.bytes > 0 {
                tipRow(String(format: L("overview.tipBin"), formatBytes(trash.bytes)), section: .cleanup, tab: .trash)
            }
            tipRow(L("overview.tipLarge"), section: .clutter, tab: .large)
            tipRow(L("overview.tipApps"), section: .apps, tab: .unused)
            tipRow(L("overview.tipStartup"), section: .performance, tab: .loginItems)
            tipRow(L("overview.tipMap"), section: .diskMap)
        }
        .padding(14)
        .depthGlass(RoundedRectangle(cornerRadius: 22))
    }

    private func tipRow(_ title: String, section: AppSection, tab: SectionTab? = nil) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(L("overview.go")) { openSection(section, tab) }
                .buttonStyle(.liquid(small: true))
                .fixedSize()
                .accessibilityHint(title)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }

    private func issueDestination(_ issue: String) -> (AppSection, SectionTab?)? {
        switch issue {
        case "health.issue.disk": (.diskMap, nil)
        case "health.issue.memory": (.performance, .maintenance)
        case "health.issue.login": (.performance, .loginItems)
        case "health.issue.junk": (.cleanup, .sweep)
        default: nil
        }
    }

    private func scoreRing(fraction: Double, value: String, label: String) -> some View {
        ZStack {
            Circle().strokeBorder(.white.opacity(0.14), lineWidth: 6)
            if fraction > 0 {
                Circle().inset(by: 3)
                    .trim(from: 0, to: fraction)
                    .stroke(section.tint, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Text(value)
                .font(.system(size: 18, weight: .bold))
                .monospacedDigit()
        }
        .frame(width: 68, height: 68)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }

    private func refreshButton(title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "arrow.clockwise")
                .symbolEffect(.rotate, options: .repeating, isActive: active && !reduceMotion)
        }
        .buttonStyle(.liquid(small: true))
        .disabled(active)
        .help(title)
        .accessibilityLabel(title)
    }

    private func overviewTile(title: String, symbol: String, value: String, detail: String? = nil) -> some View {
        VStack(spacing: 2) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(section.tint)
                .accessibilityHidden(true)
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 13, weight: .semibold)).monospacedDigit()
            if let detail {
                Text(detail).font(.system(size: 9)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, minHeight: 66, maxHeight: 66)
        .depthGlass(RoundedRectangle(cornerRadius: 16), lift: 0.8)
        .accessibilityElement(children: .combine)
    }

    private func batterySymbol(for percent: Int) -> String {
        switch percent {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }

    /// Measures the junk again (same scan as Smart Scan) and rebuilds the score from it.
    private func recheck() async {
        guard !checking else { return }
        checking = true
        let before = health?.score
        let smart = makeSmartScan(includeBrowserCaches: true)
        let sections = await Task.detached { await smart.run() }.value
        lastScanBytes = Int(sections.reduce(0) { $0 + $1.bytes })
        UserDefaults.standard.set(Date(), forKey: "lastSmartScanDate")
        await load()
        previousScore = before
        checking = false
    }

    private func load() async {
        guard !Task.isCancelled else { return }
        loading = true
        let started = Date()
        defer { if !Task.isCancelled { loading = false } }
        let home = AppEnv.shared.home
        let values = try? home.resourceValues(forKeys: [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ])
        volumeName = values?.volumeName
        total = Int64(values?.volumeTotalCapacity ?? 0)
        free = min(total, max(0, values?.volumeAvailableCapacityForImportantUsage ?? 0))
        health = healthScore(HealthInputs(freeBytes: free, totalBytes: total,
                                         memoryPressure: SystemMetrics.memoryUsed() ?? 0,
                                         loginItems: loginItems.items().count, junkBytes: Int64(lastScanBytes)))
        battery = BatteryHealth.read()
        let places = [
            (key: "tab.trash", path: ".Trash", symbol: "trash"),
            (key: "tab.downloads", path: "Downloads", symbol: "arrow.down.circle"),
            (key: "tab.appCaches", path: "Library/Caches", symbol: "shippingbox"),
            (key: "group.Logs", path: "Library/Logs", symbol: "doc.text"),
        ]
        // The four folders are sized at the same time (warm cache: ~0.58 s one by one, ~0.35 s together).
        let sizes = await withTaskGroup(of: (Int, Int64).self) { group in
            for (i, place) in places.enumerated() {
                group.addTask { (i, FS.size(of: home.appendingPathComponent(place.path))) }
            }
            var out = [Int64](repeating: 0, count: places.count)
            for await (i, bytes) in group { out[i] = bytes }
            return out
        }
        guard !Task.isCancelled else { return }
        tiles = zip(places, sizes).map { (key: $0.0.key, symbol: $0.0.symbol, bytes: $0.1) }
        // Keep the spin visible a moment: a refresh that finishes in 0.3 s looks like nothing happened.
        let left = 0.6 - Date().timeIntervalSince(started)
        if !reduceMotion, left > 0 { try? await Task.sleep(for: .seconds(left)) }
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
