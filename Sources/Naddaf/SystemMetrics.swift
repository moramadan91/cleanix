import Foundation
import Darwin

enum SystemMetrics {
    private static let host = mach_host_self()
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
        return min(1, used / Double(ProcessInfo.processInfo.physicalMemory))
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
