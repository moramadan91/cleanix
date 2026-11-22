import Foundation

/// One result card: a scanner group's total size and item count.
public struct GroupSummary: Hashable, Sendable {
    public let group: String
    public let bytes: Int64
    public let count: Int

    public init(group: String, bytes: Int64, count: Int) {
        self.group = group
        self.bytes = bytes
        self.count = count
    }
}

/// Groups in the order they were first found; the screen sorts them.
public func groupSummaries(_ items: [ScanItem]) -> [GroupSummary] {
    var order: [String] = [], bytes: [String: Int64] = [:], count: [String: Int] = [:]
    for item in items {
        if bytes[item.group] == nil { order.append(item.group) }
        bytes[item.group, default: 0] += item.bytes
        count[item.group, default: 0] += 1
    }
    return order.map { GroupSummary(group: $0, bytes: bytes[$0]!, count: count[$0]!) }
}
