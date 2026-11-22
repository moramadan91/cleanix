import Foundation

public enum Safety: Sendable { case safe, review, risky }

public struct ScanItem: Identifiable, Hashable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let bytes: Int64
    public let reason: String
    public let safety: Safety
    public let group: String

    public init(url: URL, bytes: Int64, reason: String, safety: Safety, group: String) {
        self.url = url
        self.bytes = bytes
        self.reason = reason
        self.safety = safety
        self.group = group
    }
}

/// Scanners must call `try Task.checkCancellation()` inside their loops.
public protocol Scanner: Sendable {
    func scan() async throws -> [ScanItem]
}
