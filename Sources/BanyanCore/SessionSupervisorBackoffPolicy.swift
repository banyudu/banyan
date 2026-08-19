import Foundation

/// Controls how often a session whose observation has remained unchanged needs
/// to be revisited. The supervisor still performs an immediate check for active
/// work; this policy only slows quiet, stable sessions.
public enum SessionSupervisorBackoffPolicy {
    public static let maxInterval: TimeInterval = 60 * 60
    public static let stableObservationThreshold = 3

    public static func interval(
        baseInterval: TimeInterval,
        status: SessionStatus,
        stableObservations: Int
    ) -> TimeInterval {
        guard baseInterval > 0, !requiresFrequentObservation(
            status: status,
            stableObservations: stableObservations
        ) else {
            return max(baseInterval, 0)
        }

        var interval = baseInterval
        for _ in 0..<min(max(stableObservations, 0), 10) {
            interval = min(maxInterval, interval * 2)
            if interval == maxInterval { break }
        }
        return min(interval, maxInterval)
    }

    public static func requiresFrequentObservation(
        status: SessionStatus,
        stableObservations: Int
    ) -> Bool {
        switch status {
        case .executing, .longRunningShell, .subagents:
            return true
        case .running:
            return stableObservations < stableObservationThreshold
        case .needInput, .asking, .review, .idle, .completed, .failed, .closed:
            return false
        }
    }
}
