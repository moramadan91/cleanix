import AppKit
import NaddafCore

@MainActor
func makeSmartScan(includeBrowserCaches: Bool) -> SmartScan {
    let env = AppEnv.shared
    let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    let sweep = SweepScanner(home: env.home)
    let caches = AppCacheScanner(home: env.home, appDirs: env.appDirs, runningBundleIDs: { running })
    var sections: [(name: String, scanner: any NaddafCore.Scanner)] = [
        ("tab.sweep", ClosureScanner { try await sweep.scan().filter { $0.safety == .safe } }),
        ("tab.appCaches", ClosureScanner {
            try await caches.groups().filter { !$0.isRunning && !$0.isSystem }.flatMap(\.items)
        }),
    ]
    if includeBrowserCaches {
        let privacy = PrivacyScanner(home: env.home)
        sections.append(("smart.browser", ClosureScanner { try await privacy.scan().filter { $0.safety == .safe } }))
    }
    return SmartScan(sections: sections)
}
