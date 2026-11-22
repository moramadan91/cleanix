import SwiftUI
import NaddafCore

/// The only path from a scan to `Cleaner`: the user sees every item and picks what goes.
struct PreviewSheet: View {
    let items: [ScanItem]
    let disposal: Disposal
    let onConfirm: ([ScanItem]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<URL>

    init(items: [ScanItem], disposal: Disposal, onConfirm: @escaping ([ScanItem]) -> Void) {
        self.items = items
        self.disposal = disposal
        self.onConfirm = onConfirm
        _selected = State(initialValue: Set(items.map(\.url)))
    }

    private var chosen: [ScanItem] { items.filter { selected.contains($0.url) } }
    private func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("preview.title")).font(.title2.weight(.semibold))
            if disposal == .quarantine {
                Text(L("preview.undo")).font(.callout).foregroundStyle(.secondary)
            }
            List(items) { item in
                Toggle(isOn: Binding(
                    get: { selected.contains(item.url) },
                    set: { on in if on { selected.insert(item.url) } else { selected.remove(item.url) } }
                )) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.url.lastPathComponent)
                            Text(item.reason).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(size(item.bytes)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            HStack {
                Text("\(L("common.total")): \(size(chosen.reduce(0) { $0 + $1.bytes }))").monospacedDigit()
                Spacer()
                Button(L("common.cancel")) { dismiss() }
                Button(L("common.clean")) { onConfirm(chosen); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(chosen.isEmpty)
            }
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 440)
    }
}
