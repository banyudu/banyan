import Darwin
import Foundation

/// Per-process cost counters, sampled around the measured window.
///
/// Activity Monitor's Energy Impact is a rolling platform estimate that cannot
/// be read back programmatically, so this records the inputs it is derived
/// from: CPU time, wakeups, and (on Apple silicon) cycles and instructions
/// retired. GPU work is asynchronous and is not billed here - see
/// `scripts/terminal-render-bench.sh` for the `powermetrics` companion run.
struct ProcessCostSample {
    /// `proc_pid_rusage` reports CPU time in mach absolute time units, not in
    /// nanoseconds: on Apple silicon one unit is 125/3 ns, so reading the raw
    /// value as nanoseconds under-reports CPU time by ~42x.
    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(info.denom))
    }()

    var userTicks: UInt64 = 0
    var systemTicks: UInt64 = 0
    var cycles: UInt64 = 0
    var instructions: UInt64 = 0
    var idleWakeups: UInt64 = 0
    var interruptWakeups: UInt64 = 0

    static func current() -> ProcessCostSample? {
        var info = rusage_info_v4()
        var status: Int32 = -1
        withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                status = proc_pid_rusage(getpid(), RUSAGE_INFO_V4, rebound)
            }
        }
        guard status == 0 else { return nil }
        return ProcessCostSample(
            userTicks: info.ri_user_time,
            systemTicks: info.ri_system_time,
            cycles: info.ri_cycles,
            instructions: info.ri_instructions,
            idleWakeups: info.ri_pkg_idle_wkups,
            interruptWakeups: info.ri_interrupt_wkups
        )
    }

    func delta(since start: ProcessCostSample) -> ProcessCostSample {
        ProcessCostSample(
            userTicks: userTicks &- start.userTicks,
            systemTicks: systemTicks &- start.systemTicks,
            cycles: cycles &- start.cycles,
            instructions: instructions &- start.instructions,
            idleWakeups: idleWakeups &- start.idleWakeups,
            interruptWakeups: interruptWakeups &- start.interruptWakeups
        )
    }

    private static func milliseconds(ticks: UInt64) -> Double {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000
    }

    var userMS: Double { Self.milliseconds(ticks: userTicks) }
    var systemMS: Double { Self.milliseconds(ticks: systemTicks) }
    var totalMS: Double { userMS + systemMS }
}

/// Summary statistics over the per-frame draw costs.
struct DurationSummary {
    let count: Int
    let averageMS: Double
    let p50MS: Double
    let p95MS: Double
    let p99MS: Double
    let maxMS: Double
    let totalMS: Double

    init(samples: [Double]) {
        let sorted = samples.sorted()
        count = sorted.count
        totalMS = sorted.reduce(0, +)
        averageMS = sorted.isEmpty ? 0 : totalMS / Double(sorted.count)
        maxMS = sorted.last ?? 0
        func percentile(_ fraction: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            let rank = Int((fraction * Double(sorted.count - 1)).rounded())
            return sorted[min(max(rank, 0), sorted.count - 1)]
        }
        p50MS = percentile(0.50)
        p95MS = percentile(0.95)
        p99MS = percentile(0.99)
    }
}
