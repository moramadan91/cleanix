import Foundation

private let day: TimeInterval = 24 * 60 * 60

public func shouldAlertLowSpace(free: Int64, total: Int64, lastSent: Date?, now: Date) -> Bool {
    let lowFraction = total > 0 && Double(free) / Double(total) < 0.10
    return (lowFraction || free < 15_000_000_000) && isOlder(lastSent, than: day, at: now)
}

public func shouldRemindScan(lastScan: Date?, lastSent: Date?, now: Date) -> Bool {
    isOlder(lastScan, than: 7 * day, at: now) && isOlder(lastSent, than: 7 * day, at: now)
}

private func isOlder(_ date: Date?, than interval: TimeInterval, at now: Date) -> Bool {
    date.map { now.timeIntervalSince($0) > interval } ?? true
}
