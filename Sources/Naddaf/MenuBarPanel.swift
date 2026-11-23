import AppKit
import SwiftUI

extension Notification.Name {
    static let openSmartScan = Self("cleanix.openSmartScan")
}

@MainActor
func openCleanix(smartScan: Bool, openWindow: () -> Void) {
    if !SplashDelegate.showMainWindow() { openWindow() }
    if smartScan { NotificationCenter.default.post(name: .openSmartScan, object: nil) }
}

/// Keeps the scene binding in memory and persists changes to the existing preference.
@MainActor
@Observable
final class MenuBarMonitor {
    static let shared = MenuBarMonitor()

    private static let defaultsKey = "menuBarEnabled"
    private let defaults = UserDefaults.standard
    private var enabled: Bool
    var requiresMenuBar = false {
        didSet { MenuBarStats.shared.setMonitorEnabled(isInserted) }
    }

    private init() {
        enabled = defaults.object(forKey: Self.defaultsKey) as? Bool ?? true
        MenuBarStats.shared.setMonitorEnabled(enabled)
    }

    var isEnabled: Bool {
        get { enabled }
        set {
            guard newValue != enabled else { return }
            enabled = newValue
            defaults.set(newValue, forKey: Self.defaultsKey)
            MenuBarStats.shared.setMonitorEnabled(isInserted)
        }
    }

    var isInserted: Bool {
        get { enabled || requiresMenuBar }
        set { isEnabled = newValue }
    }
}

struct MenuBarPanel: View {
    @Environment(\.openWindow) private var openWindow
    @Bindable var monitor: MenuBarMonitor
    private let stats = MenuBarStats.shared
    @AppStorage(Lang.key) private var lang = Lang.current
    @State private var isVisible = false
    @State private var disk: (free: Int64, total: Int64)?
    @State private var memorySnapshot: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            QuickBoostControls()
            Divider()
            VStack(spacing: 8) {
                metric(L("monitor.disk"), disk.map { formatBytes($0.free) })
                if let disk {
                    ProgressView(value: min(1, max(0, Double(disk.free) / Double(disk.total))))
                        .progressViewStyle(.linear)
                        .accessibilityHidden(true)
                }
                metric(L("monitor.memory"), stats.memory.map { formatPercent(Double($0) / 100) }
                       ?? memorySnapshot.map(formatPercent))
                metric(L("monitor.cpu"), stats.cpu.map { formatPercent(Double($0) / 100) })
            }
            Divider()
            HStack {
                Button(L("section.smartScan.title")) { activate(smartScan: true) }
                Button(L("monitor.open")) { activate(smartScan: false) }
            }
            Divider()
            AlertToggles()
            LoginItemToggle(isVisible: isVisible)
            MenuBarEnabledToggle(monitor: monitor)
            MenuBarStatsToggle()
        }
        .padding(16)
        .frame(width: 300)
        .preferredColorScheme(.dark)
        .environment(\.layoutDirection, Lang.direction)
        .id(lang)
        .background(PanelVisibility(isVisible: $isVisible))
        .onChange(of: isVisible) {
            guard isVisible else { return }
            disk = SystemMetrics.disk()
            updateMemorySnapshot()
        }
        .onChange(of: stats.showsStats) { if isVisible { updateMemorySnapshot() } }
    }

    private func metric(_ title: String, _ value: String?) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value ?? L("monitor.unavailable")).monospacedDigit()
        }
        .font(.system(size: 13, weight: .medium))
        .accessibilityElement(children: .combine)
    }

    private func activate(smartScan: Bool) {
        openCleanix(smartScan: smartScan) { openWindow(id: CleanixApp.mainWindowID) }
    }

    private func updateMemorySnapshot() {
        memorySnapshot = stats.showsStats ? nil : SystemMetrics.memoryUsed()
    }
}

/// The menu bar scene can retain its content when the window is ordered out.
private struct PanelVisibility: NSViewRepresentable {
    @Binding var isVisible: Bool

    func makeNSView(context: Context) -> WindowObserver {
        WindowObserver(isVisible: $isVisible)
    }

    func updateNSView(_ view: WindowObserver, context: Context) {}

    final class WindowObserver: NSView {
        private let isVisible: Binding<Bool>

        init(isVisible: Binding<Bool>) {
            self.isVisible = isVisible
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let center = NotificationCenter.default
            center.removeObserver(self)
            if let window {
                SplashDelegate.registerMonitorPanel(window)
                center.addObserver(self, selector: #selector(visibilityChanged),
                                   name: NSWindow.didChangeOcclusionStateNotification, object: window)
            }
            visibilityChanged()
        }

        @objc private func visibilityChanged() {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let visible = window.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false
                if isVisible.wrappedValue != visible { isVisible.wrappedValue = visible }
            }
        }
    }
}
