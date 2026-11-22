import Testing
import NaddafCore

private func evaluate(free: Int64 = 100, total: Int64 = 1_000, memory: Double = 0.5,
                      login: Int = 0, junk: Int64 = 0) -> HealthScore {
    healthScore(HealthInputs(freeBytes: free, totalBytes: total, memoryPressure: memory,
                             loginItems: login, junkBytes: junk))
}

@Test func healthyMacScores100() {
    let result = evaluate(free: 200)
    #expect(result.score == 100)
    #expect(result.issues.isEmpty)
    #expect(evaluate(free: 0, total: 0) == result)
}

@Test(arguments: [(49, 60), (50, 75), (99, 75), (100, 90), (199, 90), (200, 100)])
func diskThresholds(free: Int, expected: Int) {
    #expect(evaluate(free: Int64(free)).score == expected)
}

@Test(arguments: [(0.75, 100), (0.75.nextUp, 90), (0.90, 90), (0.90.nextUp, 80)])
func memoryThresholds(used: Double, expected: Int) {
    #expect(evaluate(free: 200, memory: used).score == expected)
}

@Test(arguments: [(8, 100), (9, 92), (15, 92), (16, 85)])
func loginItemThresholds(count: Int, expected: Int) {
    #expect(evaluate(free: 200, login: count).score == expected)
}

@Test(arguments: [(999_999_999, 100), (1_000_000_000, 95), (2_999_999_999, 95),
                  (3_000_000_000, 88), (9_999_999_999, 88), (10_000_000_000, 80)])
func junkThresholds(bytes: Int, expected: Int) {
    #expect(evaluate(free: 200, junk: Int64(bytes)).score == expected)
}

@Test func deductionsCombineInRuleOrder() {
    let result = evaluate(free: 1, memory: 1, login: 50, junk: 10_000_000_000)
    #expect(result.score == 5)
    #expect(result.issues == ["health.issue.disk", "health.issue.memory", "health.issue.login", "health.issue.junk"])
}
