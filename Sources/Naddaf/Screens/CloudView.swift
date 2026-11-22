import SwiftUI
import NaddafCore

/// Local cloud folders (iCloud Drive, Dropbox, OneDrive...). iCloud files can be freed from this Mac
/// (they stay in the cloud); other services are only shown. No sign-in, no network.
struct CloudView: View {
    let section: AppSection

    @State private var folders: [CloudFolder] = []
    @State private var current: CloudFolder?
    @State private var files: [ScanItem] = []
    @State private var loading = false
    @State private var message: String?

    private var scanner: CloudFoldersScanner { CloudFoldersScanner(home: AppEnv.shared.home) }

    var body: some View {
        VStack(spacing: 14) {
            if folders.isEmpty {
                Text(L("cloud.none")).foregroundStyle(.secondary).frame(maxHeight: .infinity)
            } else {
                HStack(spacing: 8) {
                    ForEach(folders, id: \.self) { folder in
                        Button { open(folder) } label: {
                            Label(folder.name, systemImage: folder.isICloud ? "icloud" : "externaldrive.connected.to.line.below")
                                .font(.system(size: 14, weight: .semibold))
                                .padding(.horizontal, 16).padding(.vertical, 8)
                                .foregroundStyle(current == folder ? Color.black : Color.white.opacity(0.85))
                                .background(Capsule().fill(current == folder ? Theme.accent : Color.white.opacity(0.08)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                if loading {
                    ScanningView()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(files) { file in
                                HStack(spacing: 12) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path)).resizable().frame(width: 28, height: 28)
                                    Text(file.url.lastPathComponent).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                                    Spacer()
                                    Text(formatBytes(file.bytes)).font(.system(size: 15, weight: .medium)).monospacedDigit()
                                    if current?.isICloud == true {
                                        Button(L("cloud.free")) { evict(file) }.buttonStyle(.glass)
                                    } else {
                                        Button(L("common.reveal")) { revealInFinder(file.url) }.buttonStyle(.glass)
                                    }
                                }
                                .modifier(RowBackground())
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                .glassPanel()
                }
                if let message { Text(message).font(.callout).foregroundStyle(Theme.accent) }
                Text(L("cloud.note")).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 40)
        .padding(.top, 20)
        .padding(.bottom, 28)
        .onAppear {
            folders = scanner.folders()
            if let first = folders.first { open(first) }
        }
    }

    private func open(_ folder: CloudFolder) {
        current = folder
        loading = true
        message = nil
        let scanner = scanner
        Task {
            files = await Task.detached { scanner.largest(in: folder, limit: 40) }.value
            loading = false
        }
    }

    private func evict(_ file: ScanItem) {
        do {
            try scanner.evict(file.url)
            files.removeAll { $0.url == file.url }
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }
}
