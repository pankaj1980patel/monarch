import Darwin
import MonarchCore
import os

/// Timing for every action, plus this process's own memory and CPU use.
/// Nothing runs in the background: samples are recorded as actions happen and
/// summarised only when the menu is opened.
final class PerformanceMonitor: Sendable {
    let stats = PerfStats()
    let signposter = OSSignposter(subsystem: "dev.monarch.Monarch", category: .pointsOfInterest)

    /// Seconds since boot on the same clock Carbon uses for event timestamps.
    static func now() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9 }

    func record(_ metric: String, since start: Double) {
        let ms = (Self.now() - start) * 1000
        guard ms >= 0, ms < 10_000 else { return }   // clock mismatch or a wildly stale event
        stats.record(metric, ms: ms)
    }

    /// Physical memory footprint in MB, the number Activity Monitor shows.
    static func memoryMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    /// Total CPU time (user + system) used since launch, in seconds.
    static func cpuSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return s(u.ru_utime) + s(u.ru_stime)
    }

    func report() -> [String] {
        stats.metrics.compactMap { m in
            guard let s = stats.summary(m) else { return nil }
            return String(format: "%@: last %.1f ms · median %.1f · p95 %.1f · max %.1f (n=%d)",
                          m, s.last, s.median, s.p95, s.max, s.count)
        }
    }
}
