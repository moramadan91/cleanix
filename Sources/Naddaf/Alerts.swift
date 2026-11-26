import AppKit
import NaddafCore
import SwiftUI
import UserNotifications

@MainActor
final class Alerts: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Alerts()

    enum Kind: String {
        case lowSpace = "alertLowSpace"
        case weeklyScan = "alertWeeklyScan"

        var lastSentKey: String { rawValue + "LastSent" }
    }

    private let defaults = UserDefaults.standard
    // The bare SwiftPM executable has no application identity for notifications.
    private let center = Bundle.main.bundleIdentifier.map { _ in UNUserNotificationCenter.current() }
    private var timer: Timer?
    private var requestingAuthorization = false
    private var sending: Set<Kind> = []

    private override init() { super.init() }

    func registerDelegate() {
        center?.delegate = self
    }

    func start() {
        guard center != nil, timer == nil else { return }
        check()
        let timer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
        timer.tolerance = 600
        self.timer = timer
    }

    func setEnabled(_ enabled: Bool, for kind: Kind) {
        defaults.set(enabled, forKey: kind.rawValue)
        guard enabled else { return }
        guard let center else {
            defaults.set(false, forKey: kind.rawValue)
            return
        }
        guard !requestingAuthorization else { return }
        requestingAuthorization = true
        Task {
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            requestingAuthorization = false
            if granted {
                check()
            } else {
                defaults.set(false, forKey: Kind.lowSpace.rawValue)
                defaults.set(false, forKey: Kind.weeklyScan.rawValue)
            }
        }
    }

    func check() {
        guard let center, !requestingAuthorization else { return }
        let now = Date()
        if defaults.bool(forKey: Kind.lowSpace.rawValue), let disk = SystemMetrics.disk(),
           shouldAlertLowSpace(free: disk.free, total: disk.total,
                               lastSent: defaults.object(forKey: Kind.lowSpace.lastSentKey) as? Date, now: now) {
            send(.lowSpace, title: L("alerts.lowSpace.title"),
                 body: String(format: L("alerts.lowSpace.body"), formatBytes(disk.free)), using: center)
        }
        if defaults.bool(forKey: Kind.weeklyScan.rawValue),
           shouldRemindScan(lastScan: defaults.object(forKey: "lastSmartScanDate") as? Date,
                            lastSent: defaults.object(forKey: Kind.weeklyScan.lastSentKey) as? Date, now: now) {
            send(.weeklyScan, title: L("alerts.weeklyScan.title"), body: L("alerts.weeklyScan.body"), using: center)
        }
    }

    private func send(_ kind: Kind, title: String, body: String, using center: UNUserNotificationCenter) {
        guard sending.insert(kind).inserted else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: kind.rawValue, content: content, trigger: nil)
        Task {
            defer { sending.remove(kind) }
            guard defaults.bool(forKey: kind.rawValue) else { return }
            if (try? await center.add(request)) != nil {
                defaults.set(Date(), forKey: kind.lastSentKey)
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        await openSmartScan()
    }

    private func openSmartScan() {
        openCleanix(smartScan: true) { SplashDelegate.reopenMainWindow?() }
    }
}

struct AlertToggles: View {
    var horizontal = false
    @AppStorage("alertLowSpace") private var lowSpace = false
    @AppStorage("alertWeeklyScan") private var weeklyScan = false

    var body: some View {
        let layout = horizontal ? AnyLayout(HStackLayout(spacing: 24)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
        layout {
            Toggle(L("alerts.lowSpace"), isOn: Binding(get: { lowSpace }) { Alerts.shared.setEnabled($0, for: .lowSpace) })
            Toggle(L("alerts.weeklyScan"), isOn: Binding(get: { weeklyScan }) { Alerts.shared.setEnabled($0, for: .weeklyScan) })
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .font(.system(size: 12))
    }
}
