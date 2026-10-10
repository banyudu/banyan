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

    /// Activity already has a bounded two-second response deadline. Do not
    /// scan the fleet to calculate an idle cadence for every PTY chunk, or
    /// while an in-flight tick owns scheduling until its completion.
    public func replacementFire(
        at now: Date,
        scheduledFire: Date?,
        activityPending: Bool,
        interval: @autoclosure () -> TimeInterval
    ) -> Date? {
        guard !isRunning else { return nil }
        guard let dueAt = nextFire(at: now, interval: activityPending ? 2 : interval()) else { return nil }
        if let scheduledFire, scheduledFire <= dueAt { return nil }
        return dueAt
    }
}
