import SwiftUI
import QuickLook
import NaddafCore

/// Generic scan screen: intro → scanning → ticked list grouped by `ScanItem.group` → review → done.
/// `.clean` goes through PreviewSheet and Cleaner; `.emptyTrash` asks a second, explicit confirmation
/// because emptying is permanent.
struct ScanListView: View {
    @Environment(\.screenStarted) private var screenStarted
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
    /// File shown in the Quick Look panel (right-click a row).
    @State private var quickLook: URL?
    /// Group whose list is open from the cards; nil shows the cards (when there are 2+ groups).
    @State private var reviewing: String?
    /// True while scanning (the lens); false while the Trash is being emptied (plain spinner).
    @State private var searching = false
    @State private var scanStart = Date()

    private var chosen: [ScanItem] { items.filter { selected.contains($0.url) } }
    @AppStorage(ListSort.key) private var sort = ListSort.largest
    /// Groups follow the chosen order too: by their total size, or by their title.
    private var groups: [String] {
        var seen: [String] = []
        for item in items where !seen.contains(item.group) { seen.append(item.group) }
        let totals = Dictionary(grouping: items, by: \.group).mapValues { $0.reduce(0) { $0 + $1.bytes } }
        return sort.sorted(seen, name: groupTitle, bytes: { totals[$0] ?? 0 })
    }
    private func sortedItems(in group: String) -> [ScanItem] {
        sort.sorted(items.filter { $0.group == group }, name: \.url.lastPathComponent, bytes: \.bytes)
    }
    private var actionTitle: String {
        if case .emptyTrash = mode { return L("trash.action") }
        return L("common.clean")
    }
    private var isReveal: Bool { if case .reveal = mode { true } else { false } }

    var body: some View {
        switch phase {
        case .intro: IntroHero(section: section) { scan() }
        case .scanning:
            if searching { LensScanView(section: section, started: scanStart) } else { ScanningView() }
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
                    if showsCards && reviewing != nil {
                        Button(L("common.back"), systemImage: "chevron.backward") { reviewing = nil }
                            .buttonStyle(.liquid(small: true))
                    }
                    let bytes = chosen.reduce(0) { $0 + $1.bytes }
                    // No size when the only pick is the Trash counted through Finder.
                    Text(String(format: L("common.itemsSelected"), chosen.count, bytes > 0 || chosen.isEmpty ? formatBytes(bytes) : "—"))
                        .font(.system(size: 14, weight: .semibold)).monospacedDigit()
                    Spacer()
                    SortMenu(sort: $sort)
                    Button(L("common.selectAll")) { selected = Set(items.map(\.url)) }.buttonStyle(.liquid(small: true))
                    Button(L("common.selectNone")) { selected = [] }.buttonStyle(.liquid(small: true))
                }
                .padding(.horizontal, 6)
                .padding(.top, 12)
                .frame(maxWidth: 560)
            }

            if items.isEmpty {
                Text(L("common.nothing")).foregroundStyle(.secondary).frame(maxHeight: .infinity)
            } else if showsCards && reviewing == nil {
                cards
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(groups.filter { reviewing == nil || $0 == reviewing }, id: \.self) { group in
                            Text(groupTitle(group)).font(.system(size: 14, weight: .bold)).foregroundStyle(.secondary)
                                .padding(.top, 6)
                            ForEach(sortedItems(in: group)) { row($0) }
                        }
                    }
                    .padding(.bottom, 8)
                }
                .scrollIndicators(.hidden)
                .glassPanel()
                .quickLookPreview($quickLook)
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

    /// Results open on one card per group when there is more than one group.
    private var showsCards: Bool { groups.count > 1 }

    private var cards: some View {
        let summaries = Dictionary(uniqueKeysWithValues: groupSummaries(items).map { ($0.group, $0) })
        return ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                ForEach(groups, id: \.self) { group in
                    if let summary = summaries[group] { card(summary) }
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 4)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: 560)
    }

    private func card(_ s: GroupSummary) -> some View {
        let urls = items.filter { $0.group == s.group }.map(\.url)
        let all = Binding(
            get: { urls.allSatisfy(selected.contains) },
            set: { if $0 { selected.formUnion(urls) } else { selected.subtract(urls) } })
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: section.symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .depthGlass(Circle(), lift: 0.4)
                Spacer()
                if !isReveal { Toggle("", isOn: all).labelsHidden().toggleStyle(.glassCheck) }
            }
            Text(groupTitle(s.group)).font(.system(size: 15, weight: .semibold)).lineLimit(1)
            Text(s.bytes > 0 ? formatBytes(s.bytes) : "—").font(.system(size: 24, weight: .bold)).monospacedDigit()
            Text(String(format: L("common.itemCount"), s.count)).font(.system(size: 12)).foregroundStyle(.secondary)
            Button(L("common.review")) { reviewing = s.group }
                .buttonStyle(.liquid(small: true))
                .padding(.top, 4)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .depthGlass(RoundedRectangle(cornerRadius: 20), lift: 0.8)
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
                // 0 = size unknown (the Trash read through Finder), not an empty item.
                Text(item.bytes > 0 ? formatBytes(item.bytes) : localized("reason", item.reason))
                    .font(.system(size: 15, weight: .medium)).monospacedDigit()
            }
        }
        .modifier(RowBackground(highlighted: isOn.wrappedValue && !isReveal))
        .contentShape(Rectangle())
        .contextMenu {
            Button(L("common.quickLook"), systemImage: "eye") { quickLook = item.url }
            Button(L("common.reveal"), systemImage: "folder") { revealInFinder(item.url) }
        }
    }

    private func scan() {
        searching = true
        scanStart = .now
        phase = .scanning
        reviewing = nil
        screenStarted()
        let scanner = makeScanner()
        Task {
            async let scanned = Task.detached { try await scanner.scan() }.value
            try? await Task.sleep(for: .seconds(LensScanView.duration)) // the search is seen, not skipped
            let found = (try? await scanned) ?? []
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
        searching = false
        phase = .scanning // a big bin takes a while; show the spinner instead of a screen that seems stuck
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
