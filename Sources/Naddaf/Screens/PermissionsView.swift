import SwiftUI
import AppKit
import NaddafCore

/// Read-only list of which apps hold which privacy permissions. Changing them stays in System Settings.
struct PermissionsView: View {
    @State private var entries: [PermissionEntry] = []
    @State private var noAccess = false

    var body: some View {
        VStack(spacing: 14) {
            if noAccess {
                VStack(spacing: 14) {
                    Image(systemName: "lock.shield").font(.system(size: 48, weight: .light))
                    Text(L("perm.noAccess")).font(.system(size: 16)).multilineTextAlignment(.center)
                    Button(L("perm.openSettings")) {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.liquid(prominent: true))
                }
                .frame(maxHeight: .infinity)
            } else if entries.isEmpty {
                Text(L("common.nothing")).foregroundStyle(.secondary).frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(entries, id: \.self) { entry in
                            let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.client)
                            HStack(spacing: 12) {
                                Image(nsImage: app.map { NSWorkspace.shared.icon(forFile: $0.path) }
                                      ?? NSWorkspace.shared.icon(for: .applicationBundle))
                                    .resizable().frame(width: 28, height: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(app.map { $0.deletingPathExtension().lastPathComponent } ?? entry.client)
                                        .font(.system(size: 15, weight: .semibold)).lineLimit(1)
                                    Text(localized("perm", entry.service.replacingOccurrences(of: "kTCCService", with: "")))
                                        .font(.system(size: 12)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: entry.allowed ? "checkmark.circle.fill" : "minus.circle")
                                    .foregroundStyle(entry.allowed ? Theme.accent : .secondary)
                            }
                            .modifier(RowBackground())
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .glassPanel()
                Text(L("perm.readOnly")).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 40)
        .padding(.top, 20)
        .padding(.bottom, 28)
        .onAppear(perform: load)
    }

    private func load() {
        let db = AppEnv.shared.home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
        do {
            entries = try PermissionsReader(tccDB: db).entries().sorted { ($0.service, $0.client) < ($1.service, $1.client) }
            noAccess = false
        } catch {
            noAccess = true
        }
    }
}
