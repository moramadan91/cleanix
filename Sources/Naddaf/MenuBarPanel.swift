import AppKit
import SwiftUI

extension Notification.Name {
    static let openSmartScan = Self("cleanix.openSmartScan")
}

@MainActor
func openCleanix(smartScan: Bool, openWindow: () -> Void) {
    NSApp.activate()
    if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    } else {
        openWindow()
    }
    if smartScan { NotificationCenter.default.post(name: .openSmartScan, object: nil) }
}

struct MenuBarPanel: View {
    @Environment(\.openWindow) private var openWindow
    @AppStorage("menuBarEnabled") private var menuBarEnabled = true
    @AppStorage(Lang.key) private var lang = Lang.current
    @State private var isVisible = false
    @State private var disk: (free: Int64, total: Int64)?
    @State private var memory: Double?
    @State private var cpu: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 8) {
                metric(L("monitor.disk"), disk.map { formatBytes($0.free) })
                if let disk {
                    ProgressView(value: min(1, max(0, Double(disk.free) / Double(disk.total))))
                        .progressViewStyle(.linear)
                        .accessibilityHidden(true)
                }
                metric(L("monitor.memory"), memory.map(percent))
                metric(L("monitor.cpu"), cpu.map(percent))
            }
            Divider()
            HStack {
                Button(L("section.smartScan.title")) { activate(smartScan: true) }
                Button(L("monitor.open")) { activate(smartScan: false) }
            }
            Divider()
            AlertToggles()
            Toggle(L("monitor.enabled"), isOn: $menuBarEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: 12))
        }
        .padding(16)
        .frame(width: 300)
        .preferredColorScheme(.dark)
        .environment(\.layoutDirection, Lang.direction)
        .id(lang)
        .background(PanelVisibility(isVisible: $isVisible))
        .task(id: isVisible) {
            if isVisible { await sample() }
        }
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

    private func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)).locale(Lang.locale))
    }

    private func activate(smartScan: Bool) {
        openCleanix(smartScan: smartScan) { openWindow(id: CleanixApp.mainWindowID) }
    }

    private func sample() async {
        var previous: SystemMetrics.CPUTicks?
        while !Task.isCancelled {
            disk = SystemMetrics.disk()
            memory = SystemMetrics.memoryUsed()
            let current = SystemMetrics.CPUTicks.read()
            cpu = previous.flatMap { earlier in current?.usage(since: earlier) }
            previous = current
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
        }
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
