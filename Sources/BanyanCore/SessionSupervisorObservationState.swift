import Foundation

/// Per-session state, copied into a tick so activity arriving during inspection
/// cannot be overwritten by that tick's older result.
public struct SessionSupervisorObservationState: Sendable {
    public private(set) var lastObservation: SessionStatusObservation?
    public private(set) var lastPane: TmuxPaneSnapshot?
    public private(set) var stableObservations = 0
    public private(set) var nextDueAt = Date.distantPast
    public private(set) var fastUntil = Date.distantPast
    public private(set) var revision: UInt64 = 0
    public private(set) var resultRevision: UInt64 = 0

    public init() {}

    public mutating func noteActivity(at now: Date, invalidatesObservation: Bool = false) {
        revision &+= 1
        if invalidatesObservation { resultRevision &+= 1 }
        stableObservations = 0
        fastUntil = now.addingTimeInterval(SessionSupervisorBackoffPolicy.fastWindow)
        nextDueAt = min(nextDueAt, now)
    }

    public func requiresFrequentObservation(status: SessionStatus, isSelectedAttached: Bool, at now: Date) -> Bool {
        SessionSupervisorBackoffPolicy.requiresFrequentObservation(
            status: status,
            stableObservations: stableObservations,
            hasRecentActivity: now < fastUntil,
            isSelectedAttached: isSelectedAttached
        )
    }

    public func nextProbeInterval(baseInterval: TimeInterval, status: SessionStatus, isSelectedAttached: Bool, at now: Date) -> TimeInterval {
        if lastObservation == nil || requiresFrequentObservation(status: status, isSelectedAttached: isSelectedAttached, at: now) {
            return baseInterval
        }
        let interval = max(1, nextDueAt.timeIntervalSince(now))
        if [.executing, .longRunningShell, .subagents].contains(status) {
            return min(SessionSupervisorCadencePolicy.activityProbeMaxInterval, interval)
        }
        return interval
    }

    /// The cheap batched pane lookup also wakes sessions whose expensive
    /// classification was deferred. Missing activity metadata cannot prove quiet.
    public func isDue(pane: TmuxPaneSnapshot?, at now: Date) -> Bool {
        nextDueAt <= now || pane != lastPane || pane?.lastActivityAt == nil
    }

    public mutating func record(
        _ observation: SessionStatusObservation?,
        pane: TmuxPaneSnapshot?,
        startedRevision: UInt64,
        at now: Date,
        baseInterval: TimeInterval,
        isSelectedAttached: Bool
    ) {
        guard revision == startedRevision else { return }
        guard let observation else {
            nextDueAt = now.addingTimeInterval(baseInterval)
            return
        }
        if lastObservation != observation || lastPane != pane {
            noteActivity(at: now)
        } else {
            stableObservations = min(stableObservations + 1, 10)
        }
        lastObservation = observation
        lastPane = pane
        let interval = SessionSupervisorBackoffPolicy.interval(
            baseInterval: baseInterval,
            status: observation.status,
            stableObservations: stableObservations,
            hasRecentActivity: now < fastUntil,
            isSelectedAttached: isSelectedAttached
        )
        nextDueAt = now.addingTimeInterval(interval)
    }
}
