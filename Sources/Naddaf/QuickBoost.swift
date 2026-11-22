import NaddafCore
import SwiftUI

@MainActor
@Observable
private final class QuickBoost {
    static let shared = QuickBoost()

    enum Phase {
        case idle, scanning, confirm([ScanItem], bytes: Int64), running
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
        phase = .running
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                let env = AppEnv.shared
                let cleaned = await env.cleaner.clean(items, disposal: .quarantine)
                let before = SystemMetrics.memoryUsed()
                let maintenance = await runMaintenance(
                    [.freeRAM], home: env.home, runner: AdminPromptRunner(), installPurgeAccess: installPurgeAccess)
                let after = SystemMetrics.memoryUsed()
                if case .success = maintenance[.freeRAM] {
                    return Phase.result(bytes: cleaned.freedBytes, before: before, after: after)
                }
                return Phase.result(bytes: cleaned.freedBytes, before: nil, after: nil)
            }.value
            PurgeAccessStatus.shared.refresh()
            phase = result
            try? await Task.sleep(for: .seconds(6))
            phase = .idle
        }
    }
}

struct QuickBoostControls: View {
    private let boost = QuickBoost.shared
    @Bindable private var purgeAccess = PurgeAccessStatus.shared

    var body: some View {
        switch boost.phase {
        case .idle:
            Button(action: boost.scan) {
                Label(L("boost.title"), systemImage: "bolt.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.liquid(prominent: true))
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
        case .running:
            progress(L("boost.running"))
        case let .result(bytes, before, after):
            let freed = formatBytes(bytes)
            if let before, let after {
                Text(String(format: L("boost.result"), freed, formatPercent(before), formatPercent(after)))
                    .monospacedDigit()
            } else {
                Text(String(format: L("boost.resultCachesOnly"), freed))
                    .monospacedDigit()
            }
        }
    }

    private func progress(_ title: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).accessibilityHidden(true)
            Text(title)
        }
    }
}
