import Testing
import Foundation
@testable import NaddafCore

@Test func cpuPercentFromTwoSamples() {
    // 0.5 s of CPU time over 1 s of wall time = 50 %.
    #expect(ProcessUsage.cpuPercent(fromNanos: 1_000_000_000, toNanos: 1_500_000_000, seconds: 1) == 50)
    #expect(ProcessUsage.cpuPercent(fromNanos: 5, toNanos: 3, seconds: 1) == 0) // pid reused: no negative
    #expect(ProcessUsage.cpuPercent(fromNanos: 0, toNanos: 10, seconds: 0) == 0)
}

@Test func descendantsFollowTheWholeTree() {
    let parents: [Int32: Int32] = [10: 1, 11: 10, 12: 11, 13: 10, 20: 1]
    #expect(ProcessUsage.descendants(of: 10, parents: parents) == [11, 12, 13])
    #expect(ProcessUsage.descendants(of: 20, parents: parents).isEmpty)
}

@Test func sampleReadsThisProcess() throws {
    let s = try #require(ProcessUsage.sample(pid: getpid()))
    #expect(s.memory > 0)
}
