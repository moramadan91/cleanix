import SwiftUI
import AppKit
import NaddafCore

/// Per-app cache cleaning: scan every app, the user ticks which apps to clear.
/// Removed folders go to Quarantine, so a clean can be undone for 30 days.
struct AppCachesView: View {
    let section: AppSection

    private enum Phase { case intro, scanning, results, done }

    @State private var phase = Phase.intro
    @State private var groups: [AppCacheGroup] = []
    @State private var selected: Set<String> = []
    @State private var expanded: Set<String> = []
    @State private var showSystem = false
    @State private var showPreview = false
    @State private var result = CleanResult()
    @State private var undoRecords: [QuarantineRecord] = []

    private var visible: [AppCacheGroup] { groups.filter { showSystem || !$0.isSystem } }
    private var chosen: [AppCacheGroup] { visible.filter { selected.contains($0.id) } }
    private var chosenBytes: Int64 { chosen.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        switch phase {
        case .intro:
            IntroHero(section: section) { scan() }
        case .scanning:
            ScanningView(text: L("caches.scanning"))
        case .results:
            results
        case .done:
            DoneView(result: result, undoable: !undoRecords.isEmpty,
                     onUndo: undoRecords.isEmpty ? nil : { undo() }, onRescan: { scan() })
        }
    }

    // MARK: results

    private var results: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Text(String(format: L("caches.selected"), chosen.count, formatBytes(chosenBytes)))
                    .font(.system(size: 16, weight: .semibold)).monospacedDigit()
                Spacer()
                Toggle(L("caches.showSystem"), isOn: $showSystem).toggleStyle(.switch).controlSize(.small)
                Button(L("common.selectAll")) { selected = Set(visible.map(\.id)) }
                Button(L("common.selectNone")) { selected = [] }
            }
            .padding(.horizontal, 6)

            if visible.isEmpty {
                Text(L("caches.empty")).foregroundStyle(.secondary).frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(visible) { row($0) }
                    }
                    .padding(.bottom, 8)
                }
                .scrollIndicators(.hidden)
                .glassPanel()
            }

            ActionButton(title: L("common.clean"), disabled: chosen.isEmpty) { showPreview = true }
        }
        .padding(.horizontal, 40)
        .padding(.bottom, 28)
        .sheet(isPresented: $showPreview) {
            PreviewSheet(section: section, items: chosen.flatMap(\.items), disposal: .quarantine) { clean($0) }
        }
    }

    private func row(_ group: AppCacheGroup) -> some View {
        let isOn = Binding(
            get: { selected.contains(group.id) },
            set: { if $0 { selected.insert(group.id) } else { selected.remove(group.id) } })
        let isOpen = expanded.contains(group.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Toggle("", isOn: isOn).labelsHidden().toggleStyle(.glassCheck)
                Image(nsImage: icon(for: group)).resizable().frame(width: 32, height: 32)
                Text(group.appName).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                if group.isRunning {
                    Text(L("caches.quitFirst")).modifier(GlassBadge())
                }
                Spacer()
                Text(formatBytes(group.bytes)).font(.system(size: 15, weight: .medium)).monospacedDigit()
                Button {
                    if isOpen { expanded.remove(group.id) } else { expanded.insert(group.id) }
                } label: {
                    Image(systemName: "chevron.down").rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                .buttonStyle(.plain)
            }
            if isOpen {
                ForEach(group.items) { item in
                    HStack {
                        Text(displayPath(item.url))
                            .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(formatBytes(item.bytes)).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .padding(.leading, 56)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 16).fill(.white.opacity(isOn.wrappedValue ? 0.10 : 0.05)))
    }

    private func icon(for group: AppCacheGroup) -> NSImage {
        if let url = group.appURL { return NSWorkspace.shared.icon(forFile: url.path) }
        return NSWorkspace.shared.icon(for: .folder)
    }

    // MARK: actions

    private func scan() {
        phase = .scanning
        let env = AppEnv.shared
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let scanner = AppCacheScanner(home: env.home, appDirs: env.appDirs, runningBundleIDs: { running })
        Task {
            // Off the main thread: walking every cache folder can take seconds.
            let found = (try? await Task.detached { try await scanner.groups() }.value) ?? []
            groups = found
            // Running apps and system apps start unticked.
            selected = Set(found.filter { !$0.isRunning && !$0.isSystem }.map(\.id))
            expanded = []
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
