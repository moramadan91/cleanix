import SwiftUI
import AppKit
import Carbon
import NaddafCore
import Sparkle

@main
struct CleanixApp: App {
    static let mainWindowID = "main"
    @NSApplicationDelegateAdaptor(SplashDelegate.self) private var splash
    @Bindable private var monitor = MenuBarMonitor.shared

    var body: some Scene {
        WindowGroup(id: Self.mainWindowID) {
            RootView(checkForUpdates: { splash.updater.checkForUpdates(nil) })
                .preferredColorScheme(.dark)
                .background(MainWindowRegistration())
        }
        .defaultSize(width: 1060, height: 680)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesCommand { splash.updater.checkForUpdates(nil) }
                ShowMonitorCommand(monitor: monitor)
            }
        }
        Settings {
            SettingsView()
        }
        MenuBarExtra(isInserted: $monitor.isInserted) {
            MenuBarPanel(monitor: monitor)
        } label: {
            MonitorMenuBarLabel()
        }
        .menuBarExtraStyle(.window)
    }
}

private struct CheckForUpdatesCommand: View {
    @AppStorage(Lang.key) private var lang = Lang.current
    let action: () -> Void

    var body: some View {
        Button(L("update.check", language: lang), action: action)
    }
}

private struct ShowMonitorCommand: View {
    @AppStorage(Lang.key) private var lang = Lang.current
    let monitor: MenuBarMonitor

    var body: some View {
        Button(L("monitor.show", language: lang)) { monitor.isEnabled = true }
            .disabled(monitor.isEnabled)
    }
}

private struct MonitorMenuBarLabel: View {
    @AppStorage(Lang.key) private var lang = Lang.current
    private let stats = MenuBarStats.shared

    var body: some View {
        let name = L("app.name", language: lang)
        if stats.showsStats {
            let missing = L("monitor.unavailable", language: lang)
            let memory = stats.memory.map { formatPercent(Double($0) / 100) } ?? missing
            let cpu = stats.cpu.map { formatPercent(Double($0) / 100) } ?? missing
            let title = String(format: L("monitor.menuBarStats", language: lang), memory, cpu)
            if let image = statsIcon(title: title) {
                Image(nsImage: image).renderingMode(.template)
                    .accessibilityLabel(title)
            } else {
                Image(systemName: "sparkles").renderingMode(.template).accessibilityLabel(name)
            }
        } else {
            Image(systemName: "sparkles").renderingMode(.template).accessibilityLabel(name)
        }
    }

    private func statsIcon(title: String) -> NSImage? {
        // MenuBarExtra extracts a single image for its status item.
        let renderer = ImageRenderer(content: HStack(spacing: 4) {
            Image(systemName: "sparkles").font(.system(size: 13))
            Text(title).font(.system(size: 11, weight: .medium)).monospacedDigit()
        }
        .fixedSize()
        .foregroundStyle(.black)
        .environment(\.layoutDirection, Lang.direction))
        renderer.scale = 2
        let image = renderer.nsImage
        image?.isTemplate = true
        return image
    }
}

private struct MainWindowRegistration: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowObserver { WindowObserver() }
    func updateNSView(_ view: WindowObserver, context: Context) {}

    final class WindowObserver: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { SplashDelegate.registerMainWindow(window) }
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
    private var quitMonitor: Any?
    private static weak var mainWindow: NSWindow?
    private static weak var monitorPanel: NSWindow?
    private static let registeredWindows = NSHashTable<NSWindow>.weakObjects()
    private static let suppressedWindows = NSHashTable<NSWindow>.weakObjects()
    private static var waitingForReopen = false
    private static var pendingUpdateCheck: (() -> Void)?

    func applicationWillFinishLaunching(_ notification: Notification) {
        configureSilentLogin()
        observeWindowActivation()
        NotificationCenter.default.addObserver(self, selector: #selector(mainWindowWillClose),
                                               name: NSWindow.willCloseNotification, object: nil)
    }

    private func configureSilentLogin() {
        let launchReason = NSAppleEventManager.shared().currentAppleEvent?
            .paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
        guard launchReason == keyAELaunchedAsLogInItem || Self.waitingForReopen else { return }
        Self.waitingForReopen = true
        Self.enterMenuBarMode()
        Self.registeredWindows.allObjects.forEach(Self.suppressLoginWindow)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureSilentLogin()
        Alerts.shared.registerDelegate()
        quitMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "q",
               let panel = Self.monitorPanel, panel.isVisible, event.window === panel || panel.isKeyWindow {
                NSApp.terminate(nil)
                return nil
            }
            return event
        }
        if Self.waitingForReopen {
            Self.pendingUpdateCheck = { [weak self] in self?.updater.updater.checkForUpdatesInBackground() }
            Alerts.shared.start()
            return
        }
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
        panel.orderFrontRegardless()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard Self.waitingForReopen || sender.activationPolicy() == .accessory else { return true }
        return !Self.showMainWindow()
    }

    static func registerMainWindow(_ window: NSWindow) {
        registeredWindows.add(window)
        mainWindow = window
        if waitingForReopen { suppressLoginWindow(window) }
    }

    static func registerMonitorPanel(_ window: NSWindow) { monitorPanel = window }

    static func showMainWindow() -> Bool {
        waitingForReopen = false
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        MenuBarMonitor.shared.requiresMenuBar = false
        for window in suppressedWindows.allObjects {
            window.alphaValue = 1
            window.ignoresMouseEvents = false
        }
        suppressedWindows.removeAllObjects()
        let window = mainWindow ?? registeredWindows.anyObject
        if let window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate()
        let checkForUpdates = pendingUpdateCheck
        pendingUpdateCheck = nil
        checkForUpdates?()
        return window != nil
    }

    @objc private func mainWindowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, Self.registeredWindows.contains(window) else { return }
        Self.registeredWindows.remove(window)
        Self.suppressedWindows.remove(window)
        if Self.mainWindow === window { Self.mainWindow = nil }
        guard !Self.registeredWindows.allObjects.contains(where: { $0.isVisible || $0.isMiniaturized }) else { return }
        Self.enterMenuBarMode()
    }

    private static func enterMenuBarMode() {
        NSApp.setActivationPolicy(.accessory)
        MenuBarMonitor.shared.requiresMenuBar = true
    }

    private static func suppressLoginWindow(_ window: NSWindow) {
        suppressedWindows.add(window)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.orderOut(nil)
    }

    private func observeWindowActivation() {
        // The SwiftUI window may appear a moment after launch: hide it the moment it shows up.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let w = note.object as? NSWindow
                MainActor.assumeIsolated {
                    guard let self, let w, w !== self.panel else { return }
                    if self.splashing { self.hide(w) }
                    if Self.waitingForReopen, Self.suppressedWindows.contains(w) { Self.suppressLoginWindow(w) }
                }
            })
        }
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
        Alerts.shared.start()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            self?.panel?.orderOut(nil)
            self?.panel = nil
            // Every launch, not only once a day: silent unless a new version exists.
            self?.updater.updater.checkForUpdatesInBackground()
        }
    }
}
