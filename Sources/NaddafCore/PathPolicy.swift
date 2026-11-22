import Foundation

/// Allowlist of roots that may be modified. A candidate is allowed only if, after
/// resolving symlinks and `..`, it lies strictly inside one of the (resolved) roots.
public struct PathPolicy: Sendable {
    private let roots: [[String]]

    public init(allowedRoots: [URL]) {
        roots = allowedRoots.map { Self.components($0) }
    }

    public func isAllowed(_ url: URL) -> Bool {
        let candidate = Self.components(url)
        return roots.contains { root in
            candidate.count > root.count && Array(candidate.prefix(root.count)) == root
        }
    }

    private static func components(_ url: URL) -> [String] {
        url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
    }
}
