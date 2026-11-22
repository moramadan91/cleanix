import AppKit
import NaddafCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @AppStorage(Lang.key) private var lang = Lang.current

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LoginItemToggle()
            Divider()
            MenuBarEnabledToggle(monitor: .shared)
            MenuBarStatsToggle()
            Divider()
            PurgeAccessSettings()
            Divider()
            AlertToggles()
        }
        .padding(20)
        .frame(width: 330, alignment: .leading)
        .preferredColorScheme(.dark)
        .environment(\.layoutDirection, Lang.direction)
        .id(lang)
    }
}

@MainActor
@Observable
final class PurgeAccessStatus {
    static let shared = PurgeAccessStatus()
    private(set) var isInstalled = PurgeAccess.isInstalled
    var installWithNextPurge = true

    func refresh() {
        isInstalled = PurgeAccess.isInstalled
    }
}

private struct PurgeAccessSettings: View {
    private let access = PurgeAccessStatus.shared
    @State private var changing = false
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("purgeAccess.title"))
                    Text(L(access.isInstalled ? "purgeAccess.on" : "purgeAccess.off"))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(L(access.isInstalled ? "purgeAccess.turnOff" : "purgeAccess.turnOn")) {
                    setEnabled(!access.isInstalled)
                }
                .disabled(changing)
            }
            Text(L("purgeAccess.note"))
                .foregroundStyle(.secondary)
            if failed {
                Text(L("purgeAccess.failed"))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12))
        .onAppear { access.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            access.refresh()
        }
    }

    private func setEnabled(_ enabled: Bool) {
        changing = true
        failed = false
        Task {
            do {
                try await Task.detached { try await PurgeAccess.setEnabled(enabled) }.value
                if !enabled { access.installWithNextPurge = false }
            } catch {
                failed = true
            }
            access.refresh()
            changing = false
        }
    }
}

struct MenuBarEnabledToggle: View {
    @Bindable var monitor: MenuBarMonitor

    var body: some View {
        Toggle(L("monitor.enabled"), isOn: $monitor.isEnabled)
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.system(size: 12))
    }
}

struct MenuBarStatsToggle: View {
    @Bindable private var stats = MenuBarStats.shared

    var body: some View {
        Toggle(L("monitor.showStats"), isOn: $stats.showsStats)
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.system(size: 12))
    }
}

@MainActor
@Observable
private final class LoginItem {
    static let shared = LoginItem()

    private let service = SMAppService.mainApp
    private(set) var status: SMAppService.Status
    private(set) var failed = false

    private init() {
        status = service.status
    }

    func refresh() {
        status = service.status
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled { try service.register() }
            else { try service.unregister() }
            failed = false
        } catch {
            failed = true
        }
        refresh()
    }
}

struct LoginItemToggle: View {
    var isVisible = true
    private let item = LoginItem.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(L("login.enabled"), isOn: Binding(
                get: { item.status == .enabled }, set: { item.setEnabled($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(item.status == .requiresApproval)

            if item.status == .requiresApproval {
                Text(L("login.approval")).foregroundStyle(.secondary)
                Button(L("login.openSettings")) { SMAppService.openSystemSettingsLoginItems() }
            }
            if item.failed {
                Text(L("login.failed")).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .font(.system(size: 12))
        .onAppear { item.refresh() }
        .onChange(of: isVisible) { if isVisible { item.refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            item.refresh()
        }
    }
}
