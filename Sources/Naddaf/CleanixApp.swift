import SwiftUI
import AppKit
import NaddafCore
import Sparkle

@main
struct CleanixApp: App {
    @NSApplicationDelegateAdaptor(SplashDelegate.self) private var splash

    var body: some Scene {
        WindowGroup {
            RootView(checkForUpdates: { splash.updater.checkForUpdates(nil) })
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                Button(L("update.check")) { splash.updater.checkForUpdates(nil) }
            }
        }
    }
}

/// Shows the logo intro alone on the desktop (a borderless, see-through panel), keeping the app window
/// invisible until the logo starts to leave, then fades the window in.
@MainActor
final class SplashDelegate: NSObject, NSApplicationDelegate {
    /// Signed updates from GitHub Releases (feed and public key in Info.plist, see scripts/release.sh).
    /// Checks on every launch (see reveal) and daily while open; asks before installing.
    let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    private var panel: NSPanel?
    private var observers: [Any] = []
    private var splashing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let side: CGFloat = 560
        let screen = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let panel = NSPanel(contentRect: NSRect(x: screen.midX - side / 2, y: screen.midY - side / 2, width: side, height: side),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: IntroView { [weak self] in self?.reveal() })
        self.panel = panel
        splashing = true

        mainWindows.forEach(hide)
        // The SwiftUI window may appear a moment after launch: hide it the moment it shows up.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let w = note.object as? NSWindow
                MainActor.assumeIsolated {
                    guard let self, self.splashing, let w, w !== self.panel else { return }
                    self.hide(w)
                }
            })
        }
        panel.orderFrontRegardless()
    }

    private var mainWindows: [NSWindow] { NSApp.windows.filter { $0 !== panel && $0.canBecomeMain } }

    private func hide(_ w: NSWindow) {
        w.alphaValue = 0
        w.ignoresMouseEvents = true
    }

    /// Called as the logo starts leaving: the window fades in under it, then the panel goes.
    private func reveal() {
        splashing = false
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        NSApp.activate()
        for w in mainWindows {
            w.ignoresMouseEvents = false
            w.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.45
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                w.animator().alphaValue = 1
            }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            self?.panel?.orderOut(nil)
            self?.panel = nil
            // Every launch, not only once a day: silent unless a new version exists.
            self?.updater.updater.checkForUpdatesInBackground()
        }
    }
}
