import SwiftUI
import NaddafCore
import UniformTypeIdentifiers

struct QuarantineView: View {
    @Environment(\.screenIsVisible) private var isVisible

    @State private var entries: [QuarantineEntry] = []
    @State private var measurements: [URL: QuarantineMeasurement] = [:]
    @State private var generation = 0
    @State private var filter: QuarantineVerdict?
    @State private var isLoading = true
    @State private var isWorking = false
    @State private var notice: Notice?

    private enum Notice {
        case delete(QuarantineEntry)
        case deleteSafe([QuarantineRecord], String)
        case error(String)

        var title: String {
            switch self {
            case .delete: L("quarantine.confirmDeleteTitle")
            case .deleteSafe: L("quarantine.confirmSafeTitle")
            case .error: L("quarantine.errorTitle")
            }
        }

        var message: String {
            switch self {
            case .delete(let entry):
                String(format: L("quarantine.confirmDeleteBody"), entry.name)
            case .deleteSafe(let records, let size):
                String(format: L("quarantine.confirmSafeBody"), locale: Lang.locale, records.count, size)
            case .error(let key):
                L(key)
            }
        }
    }

    var body: some View {
        let groups = Dictionary(grouping: entries, by: \.verdict)
        let safe = groups[.safe, default: []]
        let shown = filter.map { groups[$0, default: []] } ?? entries
        VStack(spacing: 14) {
            if isLoading && entries.isEmpty {
                ProgressView(L("quarantine.loading"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 10) {
                    Text(String(format: L("quarantine.summary"), locale: Lang.locale,
                                entries.count, totalSize(of: entries)))
                        .font(.system(size: 14, weight: .semibold)).monospacedDigit()
                        .accessibilityAddTraits(.isHeader)
                    HStack(spacing: 8) {
                        chip(nil, count: entries.count)
                        ForEach(QuarantineVerdict.allCases, id: \.self) { verdict in
                            chip(verdict, count: groups[verdict, default: []].count)
                        }
                    }
                }
                if shown.isEmpty {
                    Text(L(entries.isEmpty ? "quarantine.empty" : "quarantine.emptyFilter"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(shown) { entry in
                                QuarantineRow(entry: entry, measurement: measurements[entry.id]) {
                                    change([entry.record], restoring: true)
                                } delete: {
                                    notice = .delete(entry)
                                }
                            }
                        }
                        .padding(.bottom, 8)
                    }
                    .scrollIndicators(.hidden)
                    .glassPanel()
                }
                if !entries.isEmpty {
                    ActionButton(title: L("quarantine.deleteSafe"), disabled: safe.isEmpty) {
                        notice = .deleteSafe(safe.map(\.record), totalSize(of: safe))
                    }
                }
            }
        }
        .padding(.horizontal, 40)
        .padding(.top, 12)
        .padding(.bottom, 28)
        .disabled(isWorking)
        .task(id: isVisible) {
            guard isVisible, !isWorking else { return }
            await reload()
        }
        .alert(notice?.title ?? "", isPresented: Binding(
            get: { isVisible && notice != nil }, set: { if !$0 { notice = nil } }
        ), presenting: notice) { alert in
            switch alert {
            case .delete(let entry):
                Button(L("quarantine.delete"), role: .destructive) { change([entry.record]) }
                Button(L("common.cancel"), role: .cancel) {}
            case .deleteSafe(let records, _):
                Button(L("quarantine.deleteSafe"), role: .destructive) { change(records) }
                Button(L("common.cancel"), role: .cancel) {}
            case .error:
                Button(L("quarantine.dismiss"), role: .cancel) {}
            }
        } message: { alert in
            Text(alert.message)
        }
    }

    private func totalSize(of entries: [QuarantineEntry]) -> String {
        let sizes = entries.compactMap { measurements[$0.id]?.bytes }
        return sizes.count == entries.count ? formatBytes(sizes.reduce(0, +)) : L("monitor.unavailable")
    }

    private func reload() async {
        generation += 1
        let request = generation
        let loaded = await QuarantineEntry.load()
        guard generation == request, !Task.isCancelled else { return }

        var measured: [URL: QuarantineMeasurement] = [:]
        for entry in loaded {
            measured[entry.id] = await QuarantineMeasurement.read(entry.record)
            guard generation == request, !Task.isCancelled else { return }
        }
        entries = loaded
        measurements = measured
        isLoading = false
    }

    private func chip(_ verdict: QuarantineVerdict?, count: Int) -> some View {
        Button {
            filter = verdict
        } label: {
            Text(String(format: L("quarantine.filterCount"), locale: Lang.locale,
                        L("quarantine.filter.\(verdict?.rawValue ?? "all")"), count))
                .monospacedDigit()
        }
        .buttonStyle(.liquid(prominent: filter == verdict, small: true))
        .accessibilityAddTraits(filter == verdict ? .isSelected : [])
    }

    private func change(_ records: [QuarantineRecord], restoring: Bool = false) {
        guard !isWorking, !records.isEmpty else { return }
        generation += 1
        let request = generation
        isWorking = true
        Task {
            defer { isWorking = false }
            let errorKey = await Self.changeRecords(records, restoring: restoring)
            guard generation == request else { return }
            if let errorKey { notice = .error(errorKey) }
            await reload()
        }
    }

    @concurrent
    private static func changeRecords(
        _ records: [QuarantineRecord], restoring: Bool
    ) async -> String? {
        let quarantine = AppEnv.shared.quarantine
        var failure: String?
        for record in records {
            do {
                if restoring {
                    try quarantine.restore(record)
                } else {
                    try quarantine.delete(record)
                }
            } catch let error as CocoaError where restoring && error.code == .fileWriteFileExists {
                failure = "quarantine.errorExists"
            } catch {
                failure = restoring ? "quarantine.errorRestore" : "quarantine.errorDelete"
            }
        }
        return failure
    }
}

private struct QuarantineEntry: Identifiable {
    let record: QuarantineRecord
    let expires: Date
    let verdict: QuarantineVerdict
    let kind: QuarantineVerdict.Kind
    let reasonKey: String
    let owner: String?

    var id: URL { record.stored }
    var name: String { record.original.lastPathComponent }

    @concurrent
    static func load() async -> [Self] {
        let env = AppEnv.shared
        let records = env.quarantine.records().sorted { $0.date > $1.date }
        guard !records.isEmpty, !Task.isCancelled else { return [] }
        let apps = await RemoverScanner(appDirs: env.appDirs, home: env.home).apps(measuringSize: false)
        let names = Dictionary(apps.map { ($0.bundleID, $0.name) }, uniquingKeysWith: { first, _ in first })
        let bundleIDs = Set(names.keys)
        let homeComponents = env.home.standardizedFileURL.pathComponents
        return records.compactMap { record in
            guard !Task.isCancelled else { return nil }
            let home = record.original.standardizedFileURL.pathComponents.starts(with: homeComponents)
                ? env.home : env.canonicalHome
            let result = QuarantineVerdict.classify(record: record, home: home,
                                                   installedBundleIDs: bundleIDs, installedAppNames: names)
            return Self(record: record,
                        expires: record.date.addingTimeInterval(Double(env.quarantine.retentionDays) * 86_400),
                        verdict: result.verdict, kind: result.kind, reasonKey: result.reasonKey, owner: result.owningApp)
        }
    }
}

private struct QuarantineMeasurement: Sendable {
    let bytes: Int64
    let childCount: Int?
    let isDirectory: Bool

    @concurrent
    static func read(_ record: QuarantineRecord) async -> Self? {
        guard let stored = AppEnv.shared.quarantine.storedURL(for: record),
              let values = try? stored.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return nil }
        guard values.isSymbolicLink == false else { return Self(bytes: 0, childCount: nil, isDirectory: false) }
        let isDirectory = values.isDirectory == true
        let count = isDirectory ? (try? FileManager.default.contentsOfDirectory(atPath: stored.path).count) : nil
        return Self(bytes: FS.size(of: stored), childCount: count, isDirectory: isDirectory)
    }
}

private struct QuarantineRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.screenIsVisible) private var isVisible

    let entry: QuarantineEntry
    let measurement: QuarantineMeasurement?
    let restore: () -> Void
    let delete: () -> Void
    @State private var expanded = false

    private static let icons = NSCache<NSString, NSImage>()

    private var icon: NSImage {
        let ext = entry.record.original.pathExtension.lowercased()
        let type = measurement?.isDirectory == true && ext != "app"
            ? UTType.folder : UTType(filenameExtension: ext) ?? .data
        let key = type.identifier as NSString
        if let cached = Self.icons.object(forKey: key) { return cached }
        let image = NSWorkspace.shared.icon(for: type)
        Self.icons.setObject(image, forKey: key)
        return image
    }

    private var badgeColor: Color {
        switch entry.verdict {
        case .safe: .green
        case .review: .yellow
        case .unsafe: .red
        }
    }

    private var kindLabel: String {
        let kind = L(entry.kind.labelKey)
        guard let owner = entry.owner else { return kind }
        return String(format: L("quarantine.kindAndOwner"), kind, owner)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(nsImage: icon).resizable().frame(width: 28, height: 28).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.name).font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary).lineLimit(1)
                    Text(kindLabel).lineLimit(1)
                    Text(displayPath(entry.record.original)).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Text(measurement.map { formatBytes($0.bytes) } ?? L("monitor.unavailable")).monospacedDigit()
                Button {
                    withAnimation(reduceMotion || !isVisible ? nil : .easeInOut(duration: 0.18)) {
                        expanded.toggle()
                    }
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.liquid(small: true))
                .accessibilityLabel(L(expanded ? "quarantine.hideDetails" : "quarantine.showDetails"))
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle().fill(badgeColor).frame(width: 8, height: 8).accessibilityHidden(true)
                    Text(L("quarantine.verdict.\(entry.verdict.rawValue)"))
                }
                .modifier(GlassBadge())
                Text(L(entry.reasonKey)).lineLimit(1)
            }

            HStack(spacing: 8) {
                TimelineView(.animation(minimumInterval: 60, paused: !isVisible)) { context in
                    VStack(alignment: .leading, spacing: 2) {
                        let relative = entry.record.date.formatted(Date.RelativeFormatStyle(locale: Lang.locale))
                        Text(String(format: L("quarantine.removedRelative"), relative))
                        let days = Int(ceil(entry.expires.timeIntervalSince(context.date) / 86_400))
                        Text(days > 0 ? String(format: L("quarantine.expiry"), locale: Lang.locale, days)
                             : L("quarantine.overdue"))
                    }
                }
                Spacer()
                Button(L("quarantine.restore"), action: restore).buttonStyle(.liquid(small: true))
                Button(L("quarantine.delete"), role: .destructive, action: delete).buttonStyle(.liquid(small: true))
            }
            if expanded { details }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .modifier(RowBackground(highlighted: expanded))
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            detail("quarantine.originalPath", entry.record.original.path)
            detail("quarantine.storedPath", entry.record.stored.path)
            if let measurement {
                detail("quarantine.exactSize", String(format: L("quarantine.bytes"),
                      measurement.bytes.formatted(.number.locale(Lang.locale))))
            }
            detail("quarantine.removedDate", entry.record.date.formatted(.dateTime.year().month().day()
                .hour().minute().second().locale(Lang.locale)))
            detail("quarantine.reasonLabel", L(entry.reasonKey))
            if let count = measurement?.childCount {
                detail("quarantine.children", count.formatted(.number.locale(Lang.locale)))
            }
        }
        .textSelection(.enabled)
    }

    private func detail(_ key: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L(key)).fontWeight(.semibold)
            Text(value).foregroundStyle(.primary)
        }
    }
}
