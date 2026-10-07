import Foundation

/// Single-flight, completion-relative scheduling. Due requests made during a
/// tick are represented by session state, never by a queue of timer firings.
public struct SessionSupervisorTickSchedule: Sendable {
    public private(set) var isRunning = false
    private var restUntil = Date.distantPast

    public init() {}

    public mutating func begin() -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        return true
    }

    public mutating func finish(at completion: Date, minimumRest: TimeInterval) {
        isRunning = false
        restUntil = SessionSupervisorCadencePolicy.nextScheduledTick(after: completion, interval: minimumRest)
    }

    public func nextFire(at now: Date, interval: TimeInterval) -> Date? {
        guard !isRunning else { return nil }
        return max(restUntil, SessionSupervisorCadencePolicy.nextScheduledTick(after: now, interval: interval))
    }
}
