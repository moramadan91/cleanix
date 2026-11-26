import Foundation

/// Allowlist of roots that may be modified. A candidate is allowed only if, after
/// resolving symlinks and `..`, it lies strictly inside a root or matches an exact allowed path.
public struct PathPolicy: Sendable {
    private let roots: [[String]]
    private var exactPaths: Set<String> = []

    public init(allowedRoots: [URL]) {
        roots = allowedRoots.map { Self.components($0) }
    }

    /// Supply canonical paths recorded by discovery, without resolving them again at confirmation.
    public func allowingExactPaths(_ urls: [URL]) -> Self {
        var policy = self
        policy.exactPaths.formUnion(urls.map { $0.standardizedFileURL.path })
        return policy
    }

    public func isAllowed(_ url: URL) -> Bool {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        if exactPaths.contains(resolved.path) { return true }
        let candidate = resolved.pathComponents
        return roots.contains { root in
            candidate.count > root.count && Array(candidate.prefix(root.count)) == root
        }
    }

    private static func components(_ url: URL) -> [String] {
        url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
    }
}
