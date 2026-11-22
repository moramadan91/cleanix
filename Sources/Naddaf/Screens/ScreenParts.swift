import SwiftUI
import AppKit
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

/// Wraps any async item source as a `Scanner`, so screens can reuse `ScanListView`.
struct ClosureScanner: NaddafCore.Scanner {
    let run: @Sendable () async throws -> [ScanItem]
    func scan() async throws -> [ScanItem] { try await run() }
}

/// Catalog value for `<prefix>.<raw>`, or the raw text when the catalog has none.
func localized(_ prefix: String, _ raw: String) -> String {
    let key = "\(prefix).\(raw)"
    let value = L(key)
    return value == key ? raw : value
}

func revealInFinder(_ url: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([url])
}

/// Layered glass panel that holds a list (lists never sit straight on the background).
struct GlassPanel: ViewModifier {
    func body(content: Content) -> some View {
        // Capped width and centred: keeps lists readable and clear of the sidebar's hover pills.
        content
            .padding(8)
            .glassEffect(.regular.tint(.white.opacity(0.04)), in: .rect(cornerRadius: 22))
            .frame(maxWidth: 720)
    }
}

extension View {
    func glassPanel() -> some View { modifier(GlassPanel()) }
}

/// Glass-free list row background used by every list screen.
struct RowBackground: ViewModifier {
    var highlighted = false
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(highlighted ? 0.12 : 0.04)))
    }
}

/// Path shown with the home folder as "~".
func displayPath(_ url: URL) -> String {
    url.path(percentEncoded: false).replacingOccurrences(of: AppEnv.shared.home.path, with: "~")
}

/// Localized name of a scanner group ("Logs", "Developer"...), or the raw name if it has none.
func groupTitle(_ group: String) -> String { localized("group", group) }
