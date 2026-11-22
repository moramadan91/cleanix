import Foundation

/// Whether the app has Full Disk Access. Without it the Trash, Mail, Safari and other apps'
/// containers read as empty. Checked by opening a file only that permission unlocks.
public enum DiskAccess {
    /// TCC's own database: always present on a real home, readable only with Full Disk Access.
    public static func probe(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
    }

    /// A missing probe (e.g. a demo home) counts as granted, so the app never nags without cause.
    public static func granted(probe: URL) -> Bool {
        let fd = open(probe.path, O_RDONLY)
        if fd >= 0 { close(fd); return true }
        return !(errno == EPERM || errno == EACCES)
    }
}
