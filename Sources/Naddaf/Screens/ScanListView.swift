import SwiftUI
import NaddafCore

/// Generic scan screen: intro → scanning → ticked list grouped by `ScanItem.group` → review → done.
/// `.clean` goes through PreviewSheet and Cleaner; `.emptyTrash` asks a second, explicit confirmation
/// because emptying is permanent.
struct ScanListView: View {
    /// `.reveal` lists items for review only (no deletion), with a Show in Finder action.
    enum Mode { case clean(Disposal), emptyTrash, reveal }

    let section: AppSection
    let mode: Mode
    let makeScanner: () -> any NaddafCore.Scanner

    private enum Phase { case intro, scanning, results, done }

    @State private var phase = Phase.intro
    @State private var items: [ScanItem] = []
    @State private var selected: Set<URL> = []
    @State private var showPreview = false
    @State private var confirmEmpty = false
    @State private var result = CleanResult()
    @State private var undoRecords: [QuarantineRecord] = []

    private var chosen: [ScanItem] { items.filter { selected.contains($0.url) } }
    private var groups: [String] {
        var seen: [String] = []
        for item in items where !seen.contains(item.group) { seen.append(item.group) }
        return seen
    }
    private var actionTitle: String {
        if case .emptyTrash = mode { return L("trash.action") }
        return L("common.clean")
    }
    private var isReveal: Bool { if case .reveal = mode { true } else { false } }

    var body: some View {
        switch phase {
        case .intro: IntroHero(section: section) { scan() }
        case .scanning: ScanningView()
        case .results: results
        case .done:
            DoneView(result: result, undoable: !undoRecords.isEmpty,
                     onUndo: undoRecords.isEmpty ? nil : { undo() }, onRescan: { scan() })
        }
    }

    private var results: some View {
        VStack(spacing: 14) {
            if isReveal {
                Text(L("common.needsReview")).font(.system(size: 15)).foregroundStyle(.secondary)
                    .padding(.top, 8)
            } else if !items.isEmpty {
                HStack(spacing: 12) {
                    Text(String(format: L("common.itemsSelected"), chosen.count, formatBytes(chosen.reduce(0) { $0 + $1.bytes })))
                        .font(.system(size: 16, weight: .semibold)).monospacedDigit()
                    Spacer()
                    Button(L("common.selectAll")) { selected = Set(items.map(\.url)) }
                    Button(L("common.selectNone")) { selected = [] }
                }
                .padding(.horizontal, 6)
                .frame(maxWidth: 560)
            }

            if items.isEmpty {
                Text(L("common.nothing")).foregroundStyle(.secondary).frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(groups, id: \.self) { group in
                            Text(groupTitle(group)).font(.system(size: 14, weight: .bold)).foregroundStyle(.secondary)
                                .padding(.top, 6)
                            ForEach(items.filter { $0.group == group }) { row($0) }
                        }
                    }
                    .padding(.bottom, 8)
                }
                .scrollIndicators(.hidden)
                .glassPanel()
            }

            // Nothing found: offer a rescan instead of a disabled Clean button.
            if isReveal || items.isEmpty {
                ActionButton(title: L("common.rescan")) { scan() }
            } else {
                ActionButton(title: actionTitle, disabled: chosen.isEmpty) {
                    if case .emptyTrash = mode { confirmEmpty = true } else { showPreview = true }
                }
            }
        }
        .padding(.horizontal, 40)
        .padding(.bottom, 28)
        .sheet(isPresented: $showPreview) {
            if case .clean(let disposal) = mode {
                PreviewSheet(section: section, items: chosen, disposal: disposal) { clean($0, disposal: disposal) }
            }
        }
        .confirmationDialog(L("trash.confirmTitle"), isPresented: $confirmEmpty) {
            Button(L("trash.action"), role: .destructive) { empty() }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text(L("trash.confirmBody"))
        }
    }

    private func row(_ item: ScanItem) -> some View {
        let isOn = Binding(
            get: { selected.contains(item.url) },
            set: { if $0 { selected.insert(item.url) } else { selected.remove(item.url) } })
        return HStack(spacing: 12) {
            if !isReveal { Toggle("", isOn: isOn).labelsHidden().toggleStyle(.glassCheck) }
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path)).resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.url.lastPathComponent).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text(isReveal ? localized("reason", item.reason) : displayPath(item.url.deletingLastPathComponent()))
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if isReveal {
                Button(L("common.reveal")) { revealInFinder(item.url) }.buttonStyle(.liquid())
            } else {
                Text(formatBytes(item.bytes)).font(.system(size: 15, weight: .medium)).monospacedDigit()
            }
        }
        .modifier(RowBackground(highlighted: isOn.wrappedValue && !isReveal))
    }

    private func scan() {
        phase = .scanning
        let scanner = makeScanner()
        Task {
            let found = (try? await Task.detached { try await scanner.scan() }.value) ?? []
            items = found.sorted { $0.group == $1.group ? $0.bytes > $1.bytes : $0.group < $1.group }
            // `.review` items (user files) start unticked; `.safe` ones are ticked.
            selected = Set(found.filter { $0.safety == .safe }.map(\.url))
            if case .emptyTrash = mode { selected = Set(found.map(\.url)) }
            phase = .results
        }
    }

    private func clean(_ chosen: [ScanItem], disposal: Disposal) {
        let env = AppEnv.shared
        let start = Date()
        Task {
            let r = await Task.detached { await env.cleaner.clean(chosen, disposal: disposal) }.value
            let removed = Set(r.removed)
            undoRecords = disposal == .quarantine
                ? env.quarantine.records().filter { $0.date >= start && removed.contains($0.original) } : []
            result = r
            phase = .done
        }
    }

    private func empty() {
        let chosen = self.chosen
        let policy = PathPolicy(allowedRoots: chosen.map(\.url))
        Task {
            result = (try? await Task.detached { try await emptyTrash(chosen, confirmed: true, policy: policy) }.value) ?? CleanResult()
            undoRecords = []
            phase = .done
        }
    }

    private func undo() {
        for record in undoRecords { try? AppEnv.shared.quarantine.restore(record) }
        undoRecords = []
        scan()
    }
}
