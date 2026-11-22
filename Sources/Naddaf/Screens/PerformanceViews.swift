import SwiftUI
import AppKit
import NaddafCore

/// Checklist of maintenance tasks. Admin tasks ask for the password once, through macOS itself.
struct MaintenanceView: View {
    @State private var chosen: Set<MaintenanceTask> = [.freeRAM, .flushDNS, .speedUpMail]
    @State private var running = false
    @State private var results: [MaintenanceTask: Bool] = [:]

    private let order: [MaintenanceTask] = [.freeRAM, .flushDNS, .speedUpMail, .reindexSpotlight, .thinSnapshots]

    var body: some View {
        VStack(spacing: 14) {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(order, id: \.self) { task in
                        let isOn = Binding(
                            get: { chosen.contains(task) },
                            set: { if $0 { chosen.insert(task) } else { chosen.remove(task) } })
                        HStack(spacing: 12) {
                            Toggle("", isOn: isOn).labelsHidden().toggleStyle(.checkbox)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L("task.\(task)")).font(.system(size: 15, weight: .semibold))
                                Text(L("task.\(task).note")).font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let ok = results[task] {
                                Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(ok ? Theme.accent : .secondary)
                            }
                        }
                        .modifier(RowBackground(highlighted: isOn.wrappedValue))
                    }
                }
            }
            .scrollIndicators(.hidden)
                .glassPanel()
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
    }

    private func run() {
        running = true
        results = [:]
        let tasks = order.filter { chosen.contains($0) }
        let home = AppEnv.shared.home
        Task {
            let out = await Task.detached { await runMaintenance(tasks, home: home, runner: AdminPromptRunner()) }.value
            results = out.mapValues { if case .success = $0 { true } else { false } }
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
                                    Button(L("login.disable")) { disable(item) }.buttonStyle(.glass)
                                } else {
                                    Text(L("login.system")).font(.system(size: 12)).foregroundStyle(.secondary)
                                }
                            }
                            .modifier(RowBackground())
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
