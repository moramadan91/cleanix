import Darwin

/// Memory and CPU time of one process, read with `proc_pid_rusage` (no root needed for the user's own apps).
public struct ProcessSample: Sendable, Equatable {
    public let pid: Int32
    /// Physical footprint, the number Activity Monitor shows as "Memory".
    public let memory: Int64
    public let cpuNanos: UInt64
}

public enum ProcessUsage {
    public static func sample(pid: Int32) -> ProcessSample? {
        var info = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard ok == 0 else { return nil }
        // CPU times come in mach ticks (not nanoseconds on Apple silicon).
        let ticks = info.ri_user_time + info.ri_system_time
        return ProcessSample(pid: pid, memory: Int64(info.ri_phys_footprint), cpuNanos: ticks * UInt64(timebase.numer) / UInt64(timebase.denom))
    }

    public static func cpuPercent(fromNanos a: UInt64, toNanos b: UInt64, seconds: Double) -> Double {
        guard seconds > 0, b > a else { return 0 }
        return Double(b - a) / 1e9 / seconds * 100
    }

    /// Every pid under `root` (helpers, renderers…), from a pid → parent pid map.
    public static func descendants(of root: Int32, parents: [Int32: Int32]) -> [Int32] {
        var children: [Int32: [Int32]] = [:]
        for (pid, parent) in parents where pid != parent { children[parent, default: []].append(pid) }
        var out: [Int32] = [], queue = [root]
        while let pid = queue.popLast() {
            let kids = children[pid, default: []]
            out += kids
            queue += kids
        }
        return out.sorted()
    }

    /// pid → parent pid for every process this user can see.
    public static func parentMap() -> [Int32: Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [:] }
        var pids = [Int32](repeating: 0, count: Int(count) + 32)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        var map: [Int32: Int32] = [:]
        for pid in pids.prefix(Int(max(0, n))) where pid > 0 {
            var info = proc_bsdinfo()
            if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 {
                map[pid] = Int32(info.pbi_ppid)
            }
        }
        return map
    }

    private static let timebase: mach_timebase_info_data_t = {
        var t = mach_timebase_info_data_t()
        mach_timebase_info(&t)
        return t
    }()
}
