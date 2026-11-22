import Foundation
import Darwin

enum SystemMetrics {
    private static let host = mach_host_self()
    private static let physicalMemory = Double(ProcessInfo.processInfo.physicalMemory)
    private static let pageSize: vm_size_t? = {
        var size: vm_size_t = 0
        return host_page_size(host, &size) == KERN_SUCCESS ? size : nil
    }()

    static func disk() -> (free: Int64, total: Int64)? {
        let home = AppEnv.shared.home
        guard let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeTotalCapacityKey]),
              let free = values.volumeAvailableCapacity, let total = values.volumeTotalCapacity, total > 0 else { return nil }
        return (Int64(free), Int64(total))
    }

    static func memoryUsed() -> Double? {
        guard let pageSize else { return nil }
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let pages = UInt64(info.active_count) + UInt64(info.wire_count) + UInt64(info.compressor_page_count)
        let used = Double(pages) * Double(pageSize)
        return min(1, used / physicalMemory)
    }

    struct CPUTicks {
        private let user: UInt32
        private let system: UInt32
        private let nice: UInt32
        private let idle: UInt32

        static func read() -> Self? {
            var info = host_cpu_load_info()
            var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
                }
            }
            guard result == KERN_SUCCESS else { return nil }
            let (user, system, idle, nice) = info.cpu_ticks
            return Self(user: user, system: system, nice: nice, idle: idle)
        }

        func usage(since earlier: Self) -> Double? {
            let busy = Double(user &- earlier.user) + Double(system &- earlier.system) + Double(nice &- earlier.nice)
            let total = busy + Double(idle &- earlier.idle)
            return total > 0 ? busy / total : nil
        }
    }
}

func formatPercent(_ value: Double) -> String {
    var locale = Lang.locale
    if Lang.isArabic {
        var components = Locale.Components(locale: locale)
        components.numberingSystem = .init("arab")
        locale = Locale(components: components)
    }
    return value.formatted(.percent.precision(.fractionLength(0)).locale(locale))
}

/// Samples only while the menu bar displays the numbers.
@MainActor
@Observable
final class MenuBarStats {
    static let shared = MenuBarStats()

    private static let defaultsKey = "menuBarShowsStats"
    var showsStats = UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true {
        didSet {
            guard showsStats != oldValue else { return }
            UserDefaults.standard.set(showsStats, forKey: Self.defaultsKey)
            updateSampling()
        }
    }

    private(set) var memory: Int?
    private(set) var cpu: Int?
    @ObservationIgnored private var previous: SystemMetrics.CPUTicks?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var monitorEnabled = false

    private init() {}

    func setMonitorEnabled(_ enabled: Bool) {
        monitorEnabled = enabled
        updateSampling()
    }

    private func updateSampling() {
        guard monitorEnabled, showsStats else {
            timer?.invalidate()
            timer = nil
            previous = nil
            memory = nil
            cpu = nil
            return
        }
        guard timer == nil else { return }
        sample()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            // This timer is installed only on the main run loop.
            MainActor.assumeIsolated { self?.sample() }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func sample() {
        let memory = SystemMetrics.memoryUsed().map { Int(($0 * 100).rounded()) }
        let current = SystemMetrics.CPUTicks.read()
        let usage = previous.flatMap { earlier in current?.usage(since: earlier) }
        let cpu = usage.map { Int(($0 * 100).rounded()) }
        previous = current
        if self.memory != memory { self.memory = memory }
        if self.cpu != cpu { self.cpu = cpu }
    }
}
