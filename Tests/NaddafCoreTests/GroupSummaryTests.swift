import Foundation
import Testing
@testable import NaddafCore

@Test func groupSummariesTotalPerGroupInFirstSeenOrder() {
    let item = { (name: String, bytes: Int64, group: String) in
        ScanItem(url: URL(fileURLWithPath: "/x/\(name)"), bytes: bytes, reason: "", safety: .safe, group: group)
    }
    let s = groupSummaries([item("a", 10, "logs"), item("b", 5, "caches"), item("c", 7, "logs")])
    #expect(s == [GroupSummary(group: "logs", bytes: 17, count: 2), GroupSummary(group: "caches", bytes: 5, count: 1)])
    #expect(groupSummaries([]).isEmpty)
}
