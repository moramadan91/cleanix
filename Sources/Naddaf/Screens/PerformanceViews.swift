import SwiftUI
import AppKit
import NaddafCore

/// Selectable maintenance tasks. Admin tasks ask for the password once, through macOS itself.
struct MaintenanceView: View {
    @Environment(\.sectionTint) private var tint
    @State private var chosen: Set<MaintenanceTask> = [.freeRAM, .flushDNS, .speedUpMail]
    @State private var running = false
    @State private var results: [MaintenanceTask: Bool] = [:]
    private let order: [MaintenanceTask] = [.freeRAM, .flushDNS, .speedUpMail, .reindexSpotlight, .thinSnapshots]
    private let columns = [GridItem(.adaptive(minimum: 230), spacing: 14)]
    @Bindable private var purgeAccess = PurgeAccessStatus.shared

    var body: some View {
        VStack(spacing: 14) {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(order, id: \.self) { task in
                        card(task)
                    }
                }
                .padding(.vertical, 8)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            if chosen.contains(.freeRAM), !purgeAccess.isInstalled {
                Toggle(L("purgeAccess.offer"), isOn: $purgeAccess.installWithNextPurge)
                    .toggleStyle(.checkbox)
                    .disabled(running)
            }
            Text(L("task.adminNote")).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if running {
                ProgressView().controlSize(.large).frame(height: 52)
            } else {
                ActionButton(title: L("task.run"), disabled: chosen.isEmpty) { run() }
            }
        }
        .padding(.horizontal, 40)
        .padding(.top, 20)
        .padding(.bottom, 28)
        .onAppear { purgeAccess.refresh() }
    }

    private func card(_ task: MaintenanceTask) -> some View {
        let isOn = Binding(
            get: { chosen.contains(task) },
            set: { if $0 { chosen.insert(task) } else { chosen.remove(task) } })
        let selected = isOn.wrappedValue
        let title = L("task.\(task)")
        let note = L("task.\(task).note")
        let shape = RoundedRectangle(cornerRadius: 18)
        let status = results[task].map { L($0 ? "task.succeeded" : "task.failed") }
        return Button { isOn.wrappedValue.toggle() } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: symbol(for: task))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 36, height: 36)
                        .background(tint.opacity(0.14), in: Circle())
                    Spacer()
                    if let ok = results[task] {
                        Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(ok ? Color(hex: 0x2FD1A0) : Color(hex: 0xFF4D5E))
                            .help(status ?? "")
                    }
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? tint : .white.opacity(0.45))
                }
                Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                Text(note).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 106, alignment: .leading)
            .background(shape.fill(.white.opacity(selected ? 0.10 : 0.035)))
            .depthGlass(shape, lift: 0.55)
            .overlay(shape.strokeBorder(tint.opacity(selected ? 0.65 : 0), lineWidth: 1.5).allowsHitTesting(false))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: isOn) { Text(title) }
                .accessibilityHint([note, status].compactMap { $0 }.joined(separator: " "))
        }
        .help(note)
    }

    private func symbol(for task: MaintenanceTask) -> String {
        switch task {
        case .freeRAM: "memorychip"
        case .flushDNS: "network"
        case .speedUpMail: "envelope.badge"
        case .reindexSpotlight: "magnifyingglass"
        case .thinSnapshots: "clock.arrow.circlepath"
        }
    }

    private func run() {
        running = true
        results = [:]
        let tasks = order.filter { chosen.contains($0) }
        let home = AppEnv.shared.home
        let installPurgeAccess = purgeAccess.installWithNextPurge && !purgeAccess.isInstalled
        Task {
            let out = await Task.detached {
                await runMaintenance(tasks, home: home, runner: AdminPromptRunner(), installPurgeAccess: installPurgeAccess)
            }.value
            results = out.mapValues { if case .success = $0 { true } else { false } }
            purgeAccess.refresh()
            running = false
        }
    }
}

/// Programs that start with the Mac. User agents can be switched off (moved to Quarantine);
/// system ones are shown read-only.
struct LoginItemsView: View {
    let agentDirs: [URL]
    let daemonDirs: [URL]
    @State private var items: [LoginItem] = []
    @State private var error: String?

    private var reader: LoginItemsReader { LoginItemsReader(agentDirs: agentDirs, daemonDirs: daemonDirs) }

    var body: some View {
        VStack(spacing: 14) {
            if items.isEmpty {
                Text(L("common.nothing")).foregroundStyle(.secondary).frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(items, id: \.url) { item in
                            HStack(spacing: 12) {
                                Image(systemName: item.kind == .launchAgent ? "person.crop.circle" : "gearshape.2")
                                    .font(.system(size: 20)).frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                                    Text(item.program ?? displayPath(item.url)).font(.system(size: 12))
                                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                if item.kind == .launchAgent {
                                    Button(L("login.disable")) { disable(item) }.buttonStyle(.liquid())
                                } else {
                                    Text(L("login.system")).font(.system(size: 12)).foregroundStyle(.secondary)
                                }
                            }
                            .modifier(RowBackground(glass: true))
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .glassPanel()
            }
            if let error { Text(error).font(.callout).foregroundStyle(Theme.accent) }
            Text(L("login.note")).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(.horizontal, 40)
        .padding(.top, 20)
        .padding(.bottom, 28)
        .onAppear { items = reader.items() }
    }

    private func disable(_ item: LoginItem) {
        do {
            try reader.disable(item, using: AppEnv.shared.quarantine)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        items = reader.items()
    }
}

/// Open apps by memory (helpers included), with CPU over one second. Quit asks the app politely,
/// so it can save its work; nothing is force-killed.
struct HeavyAppsView: View {
    struct Row: Identifiable {
        let app: NSRunningApplication
        let memory: Int64
        let cpu: Double
        var id: Int32 { app.processIdentifier }
    }

    @State private var rows: [Row] = []
    @State private var loading = false

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text(L("heavy.title")).font(.system(size: 15, weight: .semibold))
                Spacer()
                Button(L("overview.refresh"), systemImage: "arrow.clockwise") { Task { await load() } }
                    .buttonStyle(.liquid(small: true)).disabled(loading)
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: 760)
            if rows.isEmpty {
                Group { if loading { ProgressView() } else { Text(L("common.nothing")).foregroundStyle(.secondary) } }
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(rows) { row in
                            HStack(spacing: 12) {
                                if let icon = row.app.icon { Image(nsImage: icon).resizable().frame(width: 30, height: 30) }
                                Text(row.app.localizedName ?? "?").font(.system(size: 15, weight: .semibold)).lineLimit(1)
                                Spacer()
                                Text(String(format: L("heavy.cpu"), row.cpu)).font(.system(size: 13)).monospacedDigit()
                                    .foregroundStyle(row.cpu > 50 ? Theme.accent : .secondary)
                                Text(formatBytes(row.memory)).font(.system(size: 15, weight: .medium)).monospacedDigit()
                                    .frame(minWidth: 80, alignment: .trailing)
                                Button(L("heavy.quit")) { quit(row.app) }.buttonStyle(.liquid())
                            }
                            .modifier(RowBackground(glass: true))
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .glassPanel()
            }
            Text(L("heavy.note")).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(.horizontal, 40)
        .padding(.top, 20)
        .padding(.bottom, 28)
        .task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        let me = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != me }
        let tree = await Task.detached { ProcessUsage.parentMap() }.value
        let groups = apps.map { app -> [Int32] in
            let pid = app.processIdentifier
            return [pid] + ProcessUsage.descendants(of: pid, parents: tree)
        }
        func read() -> [[ProcessSample]] { groups.map { $0.compactMap(ProcessUsage.sample(pid:)) } }
        let first = read(), start = Date()
        try? await Task.sleep(for: .seconds(1))
        let second = read(), seconds = Date().timeIntervalSince(start)
        rows = apps.indices.map { i in
            let before = Dictionary(uniqueKeysWithValues: first[i].map { ($0.pid, $0.cpuNanos) })
            let cpu = second[i].reduce(0.0) { sum, s in
                sum + ProcessUsage.cpuPercent(fromNanos: before[s.pid] ?? s.cpuNanos, toNanos: s.cpuNanos, seconds: seconds)
            }
            return Row(app: apps[i], memory: second[i].reduce(0) { $0 + $1.memory }, cpu: cpu)
        }
        .sorted { $0.memory > $1.memory }
    }

    private func quit(_ app: NSRunningApplication) {
        app.terminate()
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            await load()
        }
    }
}
