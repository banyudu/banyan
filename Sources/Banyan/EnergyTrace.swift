import Foundation
import OSLog
import os

/// Opt-in causal counters for the app's main-thread energy bursts.
///
/// Stacks say where the main thread spent time. These counters say which event
/// preceded the work: terminal output, a session mutation, a sidebar
/// invalidation, or a view/layout pass. Everything is off unless
/// `BANYAN_ENERGY_TRACE=1`; enabled runs aggregate in memory and emit one log
/// line every five seconds so the diagnostic never becomes a log storm.
enum EnergyTrace {
    static let enabled = ProcessInfo.processInfo.environment["BANYAN_ENERGY_TRACE"] == "1"
    private static let logger = Logger(subsystem: "dev.banyudu.banyan", category: "energy-trace")
    private static let signposter = OSSignposter(subsystem: "dev.banyudu.banyan", category: "energy-trace")
    private static let state = State()
    private static let clock = ContinuousClock()

    static func start() {
        guard enabled else { return }
        state.start()
    }

    /// Cheap counter for high-frequency boundaries. The call site is still a
    /// single boolean check when tracing is off.
    @inline(__always)
    static func count(_ name: StaticString, sessionID: String? = nil) {
        guard enabled else { return }
        state.count(name: String(describing: name), sessionID: sessionID)
    }

    /// Signposted interval for a path that should be correlated with layout in
    /// Instruments. Returns nil when tracing is off.
    static func span(_ name: StaticString, sessionID: String? = nil) -> Span? {
        guard enabled else { return nil }
        let id = signposter.makeSignpostID()
        let interval = signposter.beginInterval(name, id: id)
        return Span(name: name, sessionID: sessionID, interval: interval, startedAt: clock.now)
    }

    struct Span {
        let name: StaticString
        let sessionID: String?
        let interval: OSSignpostIntervalState
        let startedAt: ContinuousClock.Instant

        func end() {
            signposter.endInterval(name, interval)
            EnergyTrace.state.record(
                durationMS: EnergyTrace.milliseconds(startedAt.duration(to: EnergyTrace.clock.now)),
                name: String(describing: name),
                sessionID: sessionID
            )
        }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }

    private final class State: @unchecked Sendable {
        private struct Key: Hashable {
            let name: String
            let sessionID: String?
        }

        private struct DurationStat {
            var count = 0
            var totalMS = 0.0
            var maxMS = 0.0
        }

        private struct Snapshot {
            var counts: [Key: Int] = [:]
            var durations: [Key: DurationStat] = [:]
        }

        private let lock = NSLock()
        private let queue = DispatchQueue(label: "dev.banyudu.banyan.energy-trace", qos: .utility)
        private var snapshot = Snapshot()
        private var timer: DispatchSourceTimer?

        func start() {
            lock.lock()
            defer { lock.unlock() }
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .milliseconds(500))
            timer.setEventHandler { [weak self] in self?.flush() }
            timer.resume()
            self.timer = timer
        }

        func count(name: String, sessionID: String?) {
            lock.lock()
            snapshot.counts[Key(name: name, sessionID: sessionID), default: 0] += 1
            lock.unlock()
        }

        func record(durationMS: Double, name: String, sessionID: String?) {
            lock.lock()
            var stat = snapshot.durations[Key(name: name, sessionID: sessionID), default: DurationStat()]
            stat.count += 1
            stat.totalMS += durationMS
            stat.maxMS = max(stat.maxMS, durationMS)
            snapshot.durations[Key(name: name, sessionID: sessionID)] = stat
            lock.unlock()
        }

        private func flush() {
            lock.lock()
            let window = snapshot
            snapshot = Snapshot()
            lock.unlock()

            guard !window.counts.isEmpty || !window.durations.isEmpty else { return }

            var totals: [String: Int] = [:]
            for (key, value) in window.counts {
                totals[key.name, default: 0] += value
            }
            let totalText = totals
                .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ",")

            let busiest = window.counts
                .filter { $0.key.sessionID != nil }
                .sorted { $0.value == $1.value ? $0.key.name < $1.key.name : $0.value > $1.value }
                .prefix(12)
                .map { "\($0.key.name)[\($0.key.sessionID ?? "-")]=\($0.value)" }
                .joined(separator: ",")

            var durationTotals: [String: DurationStat] = [:]
            for (key, value) in window.durations {
                var stat = durationTotals[key.name, default: DurationStat()]
                stat.count += value.count
                stat.totalMS += value.totalMS
                stat.maxMS = max(stat.maxMS, value.maxMS)
                durationTotals[key.name] = stat
            }
            let spanText = durationTotals
                .sorted { $0.value.totalMS > $1.value.totalMS }
                .map { "\($0.key):n=\($0.value.count),avg_ms=\(String(format: "%.1f", $0.value.totalMS / Double(max(1, $0.value.count)))),max_ms=\(String(format: "%.1f", $0.value.maxMS))" }
                .joined(separator: ";")

            let pid = ProcessInfo.processInfo.processIdentifier
            logger.notice("pid=\(pid, privacy: .public) window_s=5 counts=\(totalText, privacy: .public) top=\(busiest, privacy: .public) spans=\(spanText, privacy: .public)")
        }
    }
}
