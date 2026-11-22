import SwiftUI
import AppKit
import NaddafCore

struct AppUpdatesView: View {
    @Environment(\.screenStarted) private var screenStarted
    let section: AppSection

    private enum Phase { case intro, checking, results }

    @State private var phase = Phase.intro
    @State private var updates: [AppUpdate] = []
    @State private var scanStart = Date()

    var body: some View {
        switch phase {
        case .intro:
            IntroHero(section: section, title: L("updates.check")) { check() }
        case .checking:
            LensScanView(section: section, started: scanStart, stages: ["updates.checking"])
        case .results:
            results
        }
    }

    private var results: some View {
        VStack(spacing: 14) {
            if updates.isEmpty {
                Text(L("updates.upToDate"))
                    .foregroundStyle(.secondary)
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(updates, id: \.app.url) { update in
                            HStack(spacing: 12) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: update.app.url.path))
                                    .resizable().frame(width: 32, height: 32)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(update.app.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                                    // Keep the installed-to-latest sequence together in RTL layouts.
                                    Text("\u{2066}\(update.installed) → \(update.latest)\u{2069}")
                                        .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                                }
                                Spacer()
                                Button(L("updates.update")) {
                                    NSWorkspace.shared.open(update.storeURL ?? update.app.url)
                                }
                                .buttonStyle(.liquid())
                            }
                            .modifier(RowBackground())
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .glassPanel()
                .frame(maxHeight: .infinity, alignment: .top)
            }
            ActionButton(title: L("common.rescan")) { check() }
        }
        .padding(.horizontal, 40)
        .padding(.top, 12)
        .padding(.bottom, 28)
    }

    private func check() {
        scanStart = .now
        phase = .checking
        screenStarted()
        let env = AppEnv.shared
        let remover = RemoverScanner(appDirs: env.appDirs, home: env.home)
        Task {
            async let found = UpdateChecker().check(remover.apps())
            try? await Task.sleep(for: .seconds(LensScanView.duration))
            updates = await found
            phase = .results
        }
    }
}
