import SwiftUI
import UniformTypeIdentifiers
import NaddafCore

/// Drop or pick files, confirm once, and they are deleted at once (no Trash, no undo).
struct ShredderView: View {
    @State private var urls: [URL] = []
    @State private var targeted = false
    @State private var picking = false
    @State private var confirm = false
    @State private var result: CleanResult?

    var body: some View {
        if let result {
            DoneView(result: result) { self.result = nil; urls = [] }
        } else {
            VStack(spacing: 16) {
                dropZone
                if !urls.isEmpty {
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(urls, id: \.self) { url in
                                HStack(spacing: 12) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 24, height: 24)
                                    Text(url.lastPathComponent).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                                    Spacer()
                                    Button { urls.removeAll { $0 == url } } label: { Image(systemName: "xmark") }
                                        .buttonStyle(.plain).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.06)))
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .frame(maxHeight: 200)
                }
                Label(L("shred.warning"), systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                ActionButton(title: L("shred.action"), disabled: urls.isEmpty) { confirm = true }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 28)
            .fileImporter(isPresented: $picking, allowedContentTypes: [.item], allowsMultipleSelection: true) { picked in
                add((try? picked.get()) ?? [])
            }
            .confirmationDialog(String(format: L("shred.confirmTitle"), urls.count), isPresented: $confirm) {
                Button(L("shred.action"), role: .destructive) { run() }
                Button(L("common.cancel"), role: .cancel) {}
            } message: {
                Text(L("trash.confirmBody"))
            }
        }
    }

    private var dropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.badge.plus").font(.system(size: 44, weight: .light))
            Text(L("shred.drop")).font(.system(size: 18, weight: .semibold))
            Button(L("shred.choose")) { picking = true }.buttonStyle(.liquid())
        }
        .frame(maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 28)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 8]))
                .foregroundStyle(targeted ? Theme.accent : .white.opacity(0.3))
        )
        .dropDestination(for: URL.self) { dropped, _ in
            add(dropped)
            return true
        } isTargeted: { targeted = $0 }
    }

    private func add(_ new: [URL]) {
        for url in new where url.isFileURL && !urls.contains(url) { urls.append(url) }
    }

    private func run() {
        let chosen = urls
        // Only files inside the user's home may be shredded; the home folder itself never.
        let policy = PathPolicy(allowedRoots: [AppEnv.shared.home])
        Task {
            result = await Task.detached { await shred(chosen, policy: policy) }.value
        }
    }
}
