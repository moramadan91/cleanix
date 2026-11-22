import Foundation
import IOKit

public struct BatteryHealth: Sendable, Equatable {
    public let cycles: Int
    public let maxCapacity: Int
    public let designCapacity: Int
    public let percent: Int

    public static func read() -> BatteryHealth? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = properties?.takeRetainedValue() as? [String: Any] else { return nil }
        return from(props)
    }

    public static func from(_ props: [String: Any]) -> BatteryHealth? {
        let batteryData = props["BatteryData"] as? [String: Any]
        guard let cycles = props["CycleCount"] as? Int, cycles >= 0,
              let maxCapacity = (props["AppleRawMaxCapacity"] as? Int)
                  ?? (batteryData?["AppleRawMaxCapacity"] as? Int) ?? (props["MaxCapacity"] as? Int),
              maxCapacity >= 0,
              let designCapacity = (props["DesignCapacity"] as? Int) ?? (batteryData?["DesignCapacity"] as? Int),
              designCapacity > 0 else { return nil }
        let percent = Int(min(100, (Double(maxCapacity) / Double(designCapacity) * 100).rounded()))
        return BatteryHealth(cycles: cycles, maxCapacity: maxCapacity, designCapacity: designCapacity, percent: percent)
    }
}
