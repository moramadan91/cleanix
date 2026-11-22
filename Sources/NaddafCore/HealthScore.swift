public struct HealthInputs: Sendable {
    public let freeBytes: Int64
    public let totalBytes: Int64
    public let memoryPressure: Double
    public let loginItems: Int
    public let junkBytes: Int64

    public init(freeBytes: Int64, totalBytes: Int64, memoryPressure: Double, loginItems: Int, junkBytes: Int64) {
        self.freeBytes = freeBytes
        self.totalBytes = totalBytes
        self.memoryPressure = memoryPressure
        self.loginItems = loginItems
        self.junkBytes = junkBytes
    }
}

public struct HealthScore: Sendable, Equatable {
    public let score: Int
    public let issues: [String]
}

public func healthScore(_ i: HealthInputs) -> HealthScore {
    var score = 100
    var issues: [String] = []

    func deduct(_ points: Int, for issue: String) {
        score -= points
        issues.append(issue)
    }

    if i.totalBytes > 0 {
        let free = Double(i.freeBytes) / Double(i.totalBytes)
        switch free {
        case ..<0.05: deduct(40, for: "health.issue.disk")
        case ..<0.10: deduct(25, for: "health.issue.disk")
        case ..<0.20: deduct(10, for: "health.issue.disk")
        default: break
        }
    }
    switch i.memoryPressure {
    case let used where used > 0.90: deduct(20, for: "health.issue.memory")
    case let used where used > 0.75: deduct(10, for: "health.issue.memory")
    default: break
    }
    switch i.loginItems {
    case 16...: deduct(15, for: "health.issue.login")
    case 9...: deduct(8, for: "health.issue.login")
    default: break
    }
    switch i.junkBytes {
    case 10_000_000_000...: deduct(20, for: "health.issue.junk")
    case 3_000_000_000...: deduct(12, for: "health.issue.junk")
    case 1_000_000_000...: deduct(5, for: "health.issue.junk")
    default: break
    }

    return HealthScore(score: max(0, min(100, score)), issues: issues)
}
