import SwiftUI
import NaddafCore

/// Tabs inside a section. Titles come from the catalog key `tab.<rawValue>`.
enum SectionTab: String, Identifiable {
    case sweep, appCaches, trash, mail, shredder
    case privacy, permissions, suspicious, extensions
    case maintenance, loginItems, heavyApps
    case uninstall, leftovers, unused, updates, reset
    case large, duplicates, similar, downloads

    var id: String { rawValue }
    var title: String { L("tab.\(rawValue)") }

    static func tabs(for section: AppSection) -> [SectionTab] {
        switch section {
        case .cleanup: [.sweep, .appCaches, .trash, .mail, .shredder]
        case .protection: [.privacy, .permissions, .suspicious, .extensions]
        case .performance: [.maintenance, .loginItems, .heavyApps]
        case .apps: [.uninstall, .leftovers, .unused, .updates, .reset]
        case .clutter: [.large, .duplicates, .similar, .downloads]
        case .overview, .smartScan, .diskMap, .cloud: []
        }
    }
}

/// Picks the screen for a section and tab, wiring each scanner to the app's home folder.
struct SectionContent: View {
    let section: AppSection
    let tab: SectionTab?

    private var env: AppEnv { .shared }
    private var home: URL { env.home }
    private var lib: URL { home.appendingPathComponent("Library") }
    private func h(_ path: String) -> URL { home.appendingPathComponent(path) }
    private var agentDirs: [URL] {
        env.isDemo ? [lib.appendingPathComponent("LaunchAgents")]
            : [lib.appendingPathComponent("LaunchAgents"), URL(fileURLWithPath: "/Library/LaunchAgents")]
    }
    private var daemonDirs: [URL] {
        env.isDemo ? [] : [URL(fileURLWithPath: "/Library/LaunchDaemons")]
    }

    var body: some View {
        switch (section, tab) {
        case (.overview, _):
            OverviewView(section: section, loginItems: LoginItemsReader(agentDirs: agentDirs, daemonDirs: daemonDirs))
        case (.smartScan, _): SmartScanView(section: section)
        case (.diskMap, _): DiskMapView(section: section)
        case (.cloud, _): CloudView(section: section)

        case (_, .appCaches?): AppCachesView(section: section)
        case (_, .sweep?):
            ScanListView(section: section, mode: .clean(.quarantine)) { SweepScanner(home: home) }
        case (_, .trash?):
            ScanListView(section: section, mode: .emptyTrash) { TrashScanner(trashRoots: [h(".Trash")]) }
        case (_, .mail?):
            ScanListView(section: section, mode: .clean(.trash)) {
                MailAttachmentsScanner(mailDownloads: [
                    lib.appendingPathComponent("Containers/com.apple.mail/Data/Library/Mail Downloads"),
                    lib.appendingPathComponent("Mail Downloads")])
            }
        case (_, .shredder?): ShredderView()

        case (_, .privacy?):
            ScanListView(section: section, mode: .clean(.quarantine)) { PrivacyScanner(home: home) }
        case (_, .permissions?): PermissionsView()
        case (_, .suspicious?):
            ScanListView(section: section, mode: .reveal) {
                SuspiciousScanner(appDirs: env.appDirs, agentDirs: agentDirs, verifier: CodesignVerifier())
            }
        case (_, .extensions?):
            ScanListView(section: section, mode: .reveal) { BrowserExtensionsScanner(home: home) }

        case (_, .maintenance?): MaintenanceView()
        case (_, .heavyApps?): HeavyAppsView()
        case (_, .loginItems?): LoginItemsView(agentDirs: [lib.appendingPathComponent("LaunchAgents")],
                                               daemonDirs: agentDirs.dropFirst() + daemonDirs)

        case (_, .uninstall?): UninstallView(section: section)
        case (_, .leftovers?):
            let remover = RemoverScanner(appDirs: env.userAppDirs, home: home)
            ScanListView(section: section, mode: .clean(.quarantine)) {
                ClosureScanner { await remover.orphanLeftovers() }
            }
        case (_, .unused?):
            let remover = RemoverScanner(appDirs: env.userAppDirs, home: home)
            ScanListView(section: section, mode: .clean(.trash)) {
                ClosureScanner {
                    var items: [ScanItem] = []
                    for app in await remover.unused(olderThanDays: 90) {
                        items.append(ScanItem(url: app.url, bytes: app.bytes, reason: "Unused app", safety: .review, group: app.name))
                        items += remover.leftovers(for: app)
                    }
                    return items
                }
            }
        case (_, .updates?): AppUpdatesView(section: section)
        case (_, .reset?): AppResetView(section: section)

        case (_, .large?):
            let roots = AppEnv.userFolders.map(h)
            ScanListView(section: section, mode: .clean(.trash)) {
                ClosureScanner {
                    var items: [ScanItem] = []
                    for root in roots {
                        items += try await ForgottenScanner(root: root, minBytes: 100_000_000, olderThanDays: 180).scan()
                    }
                    return items
                }
            }
        case (_, .duplicates?):
            let roots = AppEnv.userFolders.map(h)
            ScanListView(section: section, mode: .clean(.trash)) {
                // Extra copies start ticked: the oldest copy is always kept and never listed.
                ClosureScanner { try await DuplicatesScanner(roots: roots).groups().flatMap(\.asItems) }
            }
        case (_, .similar?):
            let roots = ["Pictures", "Desktop", "Downloads"].map(h)
            ScanListView(section: section, mode: .clean(.trash)) {
                ClosureScanner { try await SimilarImagesScanner(roots: roots).groups().flatMap { $0.asItems(safety: .review) } }
            }
        case (_, .downloads?):
            ScanListView(section: section, mode: .clean(.trash)) { DownloadsScanner(downloads: h("Downloads"), olderThanDays: 30) }

        default: EmptyView()
        }
    }
}

extension DuplicateGroup {
    /// The extra copies as items grouped under the kept file's name.
    var asItems: [ScanItem] { asItems(safety: .safe) }

    func asItems(safety: Safety) -> [ScanItem] {
        extras.map { ScanItem(url: $0.url, bytes: $0.bytes, reason: $0.reason, safety: safety, group: keep.url.lastPathComponent) }
    }
}
