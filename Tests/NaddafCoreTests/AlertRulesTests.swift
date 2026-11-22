import Foundation
import Testing
import NaddafCore

private let day: TimeInterval = 86_400
private let now = Date(timeIntervalSince1970: 1_000_000)

@Test func eitherLowSpaceThresholdCanTrigger() {
    #expect(shouldAlertLowSpace(free: 19_999_999_999, total: 200_000_000_000, lastSent: nil, now: now))
    #expect(!shouldAlertLowSpace(free: 20_000_000_000, total: 200_000_000_000, lastSent: nil, now: now))
    #expect(shouldAlertLowSpace(free: 14_999_999_999, total: 100_000_000_000, lastSent: nil, now: now))
    #expect(!shouldAlertLowSpace(free: 15_000_000_000, total: 100_000_000_000, lastSent: nil, now: now))
    #expect(!shouldAlertLowSpace(free: 15_000_000_000, total: 0, lastSent: nil, now: now))
}

@Test func lowSpaceCooldownIsStrictlyOverOneDay() {
    for (age, expected) in [(day - 1, false), (day, false), (day + 1, true)] {
        #expect(shouldAlertLowSpace(free: 0, total: 100, lastSent: now - age, now: now) == expected)
    }
}

@Test func weeklyReminderRequiresBothDatesToBeMissingOrOverdue() {
    let exact = now - 7 * day
    let overdue = exact - 1
    #expect(shouldRemindScan(lastScan: nil, lastSent: nil, now: now))
    #expect(shouldRemindScan(lastScan: overdue, lastSent: overdue, now: now))
    #expect(!shouldRemindScan(lastScan: now, lastSent: nil, now: now))
    #expect(!shouldRemindScan(lastScan: exact, lastSent: overdue, now: now))
    #expect(!shouldRemindScan(lastScan: overdue, lastSent: exact, now: now))
}
