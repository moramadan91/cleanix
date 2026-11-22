import SwiftUI
import NaddafCore

/// Spinner shown while a scan runs.
struct ScanningView: View {
    var text = L("common.scanning")

    var body: some View {
        VStack(spacing: 18) {
            ProgressView().controlSize(.large)
            Text(text).font(.system(size: 18, weight: .medium))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Result of a clean: freed size, failures, Undo (quarantine only) and Scan again.
struct DoneView: View {
    let result: CleanResult
    var undoable = false
    var onUndo: (() -> Void)?
    let onRescan: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 72)).foregroundStyle(Theme.accent)
            Text(String(format: L("common.cleaned"), formatBytes(result.freedBytes)))
                .font(.system(size: 28, weight: .bold))
            if undoable { Text(L("preview.undo")).foregroundStyle(.secondary) }
            if !result.failed.isEmpty {
                Text(String(format: L("common.failedCount"), result.failed.count)).foregroundStyle(Theme.accent)
            }
            HStack(spacing: 12) {
                if let onUndo { Button(L("common.undo"), action: onUndo).buttonStyle(.glass) }
                Button(L("common.rescan"), action: onRescan).buttonStyle(.glassProminent).tint(Theme.accent)
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Big amber action button at the bottom of a results screen.
struct ActionButton: View {
    let title: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 20, weight: .bold)).frame(width: 220, height: 52)
        }
        .buttonStyle(.glassProminent)
        .tint(Theme.accent)
        .disabled(disabled)
    }
}

/// Path shown with the home folder as "~".
func displayPath(_ url: URL) -> String {
    url.path(percentEncoded: false).replacingOccurrences(of: AppEnv.shared.home.path, with: "~")
}

/// Localized name of a scanner group ("Logs", "Developer"...), or the raw name if it has none.
func groupTitle(_ group: String) -> String {
    let key = "group.\(group)"
    let value = L(key)
    return value == key ? group : value
}
