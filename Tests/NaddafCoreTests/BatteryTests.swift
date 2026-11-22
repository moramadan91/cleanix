import Testing
import NaddafCore

@Test func laptopBatteryPrefersRawCapacityAndRounds() throws {
    let health = try #require(BatteryHealth.from([
        "CycleCount": 312, "AppleRawMaxCapacity": 4_590, "MaxCapacity": 100, "DesignCapacity": 5_000,
    ]))
    #expect(health.cycles == 312)
    #expect(health.maxCapacity == 4_590)
    #expect(health.designCapacity == 5_000)
    #expect(health.percent == 92)
}

@Test func batteryFallsBackToMaxCapacityAndCapsPercent() {
    #expect(BatteryHealth.from(["CycleCount": 0, "MaxCapacity": 6_000, "DesignCapacity": 5_000])?.percent == 100)
}

@Test func batteryReadsRawCapacityAndDesignCapacityFromBatteryData() throws {
    let health = try #require(BatteryHealth.from([
        "CycleCount": 114, "MaxCapacity": 100,
        "BatteryData": ["AppleRawMaxCapacity": 5_659, "DesignCapacity": 6_249],
    ]))
    #expect(health.maxCapacity == 5_659)
    #expect(health.designCapacity == 6_249)
    #expect(health.percent == 91)
}

@Test func invalidBatteryPropertiesReturnNil() {
    #expect(BatteryHealth.from(["CycleCount": 312, "DesignCapacity": 5_000]) == nil)
    #expect(BatteryHealth.from(["CycleCount": 312, "MaxCapacity": 4_590]) == nil)
    #expect(BatteryHealth.from(["MaxCapacity": 4_590, "DesignCapacity": 5_000]) == nil)
    #expect(BatteryHealth.from(["CycleCount": 312, "MaxCapacity": 4_590, "DesignCapacity": 0]) == nil)
    #expect(BatteryHealth.from([:]) == nil)
}
