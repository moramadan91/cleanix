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
            VStack(spacing: 18) {
                ProgressView().controlSize(.large)
                Text(L("caches.scanning")).font(.system(size: 18, weight: .medium))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .results:
            results
        case .done:
            done
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
            }

            Button { showPreview = true } label: {
                Text(L("common.clean")).font(.system(size: 20, weight: .bold)).frame(width: 220, height: 52)
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.accent)
            .disabled(chosen.isEmpty)
        }
        .padding(.horizontal, 40)
        .padding(.bottom, 28)
        .sheet(isPresented: $showPreview) {
            PreviewSheet(items: chosen.flatMap(\.items), disposal: .quarantine) { clean($0) }
        }
    }

    private func row(_ group: AppCacheGroup) -> some View {
        let isOn = Binding(
            get: { selected.contains(group.id) },
            set: { if $0 { selected.insert(group.id) } else { selected.remove(group.id) } })
        let isOpen = expanded.contains(group.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Toggle("", isOn: isOn).labelsHidden().toggleStyle(.checkbox)
                Image(nsImage: icon(for: group)).resizable().frame(width: 32, height: 32)
                Text(group.appName).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                if group.isRunning {
                    Text(L("caches.quitFirst"))
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(Theme.accent.opacity(0.22)))
                        .foregroundStyle(Theme.accent)
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
                        Text(item.url.path(percentEncoded: false).replacingOccurrences(of: AppEnv.shared.home.path, with: "~"))
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

    // MARK: done

    private var done: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 72)).foregroundStyle(Theme.accent)
            Text(String(format: L("common.cleaned"), formatBytes(result.freedBytes)))
                .font(.system(size: 28, weight: .bold))
            Text(L("preview.undo")).foregroundStyle(.secondary)
            if !result.failed.isEmpty {
                Text(String(format: L("common.failedCount"), result.failed.count)).foregroundStyle(Theme.accent)
            }
            HStack(spacing: 12) {
                if !undoRecords.isEmpty {
                    Button(L("common.undo")) { undo() }.buttonStyle(.glass)
                }
                Button(L("common.rescan")) { scan() }.buttonStyle(.glassProminent).tint(Theme.accent)
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
