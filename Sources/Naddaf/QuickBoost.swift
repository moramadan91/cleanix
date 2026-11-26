import AppKit
import NaddafCore
import SwiftUI

@MainActor
@Observable
private final class QuickBoost {
    static let shared = QuickBoost()

    enum Phase: Sendable {
        case idle, scanning, confirm([ScanItem], bytes: Int64), running(CleaningRun)
        case result(bytes: Int64, before: Double?, after: Double?)
    }

    private(set) var phase = Phase.idle

    func scan() {
        guard case .idle = phase else { return }
        phase = .scanning
        let scanner = makeSmartScan(includeBrowserCaches: false)
        Task {
            let items = await Task.detached {
                let sections = await scanner.run()
                var seen: Set<URL> = []
                return sections.flatMap(\.items).filter { seen.insert($0.url.standardizedFileURL).inserted }
            }.value
            PurgeAccessStatus.shared.refresh()
            phase = .confirm(items, bytes: items.reduce(0) { $0 + $1.bytes })
        }
    }

    func cancel() {
        if case .confirm = phase { phase = .idle }
    }

    func boost() {
        guard case let .confirm(items, _) = phase else { return }
        let access = PurgeAccessStatus.shared
        let installPurgeAccess = access.installWithNextPurge && !access.isInstalled
        let run = CleaningRun(items: items)
        let purgeTitle = L("task.freeRAM")
        phase = .running(run)
        Task {
            let result: Phase = await run.perform { progress in
                let env = AppEnv.shared
                let cleaned = await env.cleaner.clean(items, disposal: .quarantine) { name, fraction in
                    await progress(name, fraction.map { $0 * 0.8 })
                }
                await progress(purgeTitle, 0.8)
                await progress(purgeTitle, nil)
                let before = SystemMetrics.memoryUsed()
                let maintenance = await runMaintenance(
                    [.freeRAM], home: env.home, runner: AdminPromptRunner(), installPurgeAccess: installPurgeAccess)
                let after = SystemMetrics.memoryUsed()
                if case .success = maintenance[.freeRAM] {
                    return Phase.result(bytes: cleaned.freedBytes, before: before, after: after)
                }
                return Phase.result(bytes: cleaned.freedBytes, before: nil, after: nil)
            }
            PurgeAccessStatus.shared.refresh()
            phase = result
            try? await Task.sleep(for: .seconds(6))
            phase = .idle
        }
    }
}

struct QuickBoostControls: View {
    var showsQuit = false
    private let boost = QuickBoost.shared
    @Bindable private var purgeAccess = PurgeAccessStatus.shared

    var body: some View {
        if showsQuit {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    boostButton
                    Button(L("monitor.quit"), systemImage: "power") { NSApp.terminate(nil) }
                        .buttonStyle(.liquid(small: true))
                    Spacer(minLength: 0)
                }
                if !isIdle { status }
            }
        } else if isIdle {
            boostButton
        } else {
            status
        }
    }

    private var isIdle: Bool {
        if case .idle = boost.phase { return true }
        return false
    }

    private var boostButton: some View {
        Button(action: boost.scan) {
            Label(L("boost.title"), systemImage: "bolt.fill")
                .frame(maxWidth: showsQuit ? nil : .infinity)
        }
        .buttonStyle(.liquid(prominent: true, small: showsQuit))
        .disabled(!isIdle)
    }

    @ViewBuilder private var status: some View {
        switch boost.phase {
        case .idle: EmptyView()
        case .scanning:
            progress(L("boost.scanning"))
        case .confirm(_, let bytes):
            VStack(alignment: .leading, spacing: 8) {
                Text(String(format: L("boost.confirm"), formatBytes(bytes)))
                if !purgeAccess.isInstalled {
                    Toggle(L("purgeAccess.offer"), isOn: $purgeAccess.installWithNextPurge)
                        .toggleStyle(.checkbox)
                }
                HStack {
                    Button(L("boost.action"), action: boost.boost)
                        .buttonStyle(.liquid(prominent: true, small: true))
                    Button(L("common.cancel"), action: boost.cancel)
                        .buttonStyle(.liquid(small: true))
                }
            }
        case .running(let run):
            CleaningView(run: run, compact: true)
                .environment(\.sectionTint, AppSection.performance.tint)
        case let .result(bytes, before, after):
            let freed = formatBytes(bytes)
            let title = if let before, let after {
                String(format: L("boost.result"), freed, formatPercent(before), formatPercent(after))
            } else {
                String(format: L("boost.resultCachesOnly"), freed)
            }
            VStack(spacing: 8) {
                CompletionCheckmark(size: 50)
                CompletionTitle {
                    Text(title).monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func progress(_ title: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).accessibilityHidden(true)
            Text(title)
        }
    }
}
