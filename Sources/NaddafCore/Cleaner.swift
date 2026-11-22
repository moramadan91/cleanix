import Foundation

public enum Disposal: Sendable { case trash, quarantine }

public struct CleanResult: Sendable {
    public var removed: [URL] = []
    public var failed: [(url: URL, reason: String)] = []
    public var freedBytes: Int64 = 0

    public init() {}
}

/// The only code path that deletes user files. Every item must pass `PathPolicy`.
public final class Cleaner: Sendable {
    private let policy: PathPolicy
    private let quarantine: Quarantine
    private let trasher: @Sendable (URL) throws -> Void

    public init(
        policy: PathPolicy,
        quarantine: Quarantine,
        trasher: @escaping @Sendable (URL) throws -> Void = {
            try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
        }
    ) {
        self.policy = policy
        self.quarantine = quarantine
        self.trasher = trasher
    }

    public func clean(_ items: [ScanItem], disposal: Disposal) async -> CleanResult {
        var result = CleanResult()
        for item in items {
            guard policy.isAllowed(item.url) else {
                result.failed.append((item.url, "path is not allowed"))
                continue
            }
            guard FileManager.default.fileExists(atPath: item.url.path) else {
                result.failed.append((item.url, "file no longer exists"))
                continue
            }
            do {
                switch disposal {
                case .trash: try trasher(item.url)
                case .quarantine: _ = try quarantine.stash(item.url)
                }
                result.removed.append(item.url)
                result.freedBytes += item.bytes
            } catch {
                result.failed.append((item.url, error.localizedDescription))
            }
        }
        return result
    }
}
