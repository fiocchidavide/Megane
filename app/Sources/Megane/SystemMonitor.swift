import Foundation
import IOKit

/// System counters for the info panel, read only while it is open.
struct SystemMonitor {
    private var lastCPU: (wall: Double, cpu: Double)?

    /// The GPU's utilization over its last sampling period, as reported by the GPU driver
    /// (the whole system's use, not only Megane's).
    static func gpuUtilization() -> Int? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }
            guard let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
                  let utilization = stats["Device Utilization %"] as? Int else { continue }
            return utilization
        }
        return nil
    }

    /// Megane's CPU time since the last call, as a percentage of one core.
    mutating func cpuPercent() -> Double? {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        let now = (wall: Date().timeIntervalSinceReferenceDate, cpu: seconds(usage.ru_utime) + seconds(usage.ru_stime))
        defer { lastCPU = now }
        guard let last = lastCPU, now.wall > last.wall else { return nil }
        return (now.cpu - last.cpu) / (now.wall - last.wall) * 100
    }
}
