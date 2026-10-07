import Foundation

/// Bounds inspection cost without treating a long-lived executing status as
/// evidence that anything changed. Activity reopens a short fast window.
public enum SessionSupervisorBackoffPolicy {
    public static let maxInterval: TimeInterval = 60 * 60
    public static let activeMaxInterval: TimeInterval = 60
    public static let fastWindow: TimeInterval = 10
    public static let stableObservationThreshold = 3

    public static func interval(
        baseInterval: TimeInterval,
        status: SessionStatus,
        stableObservations: Int,
        hasRecentActivity: Bool = false,
        isSelectedAttached: Bool = false
    ) -> TimeInterval {
        guard baseInterval > 0, !requiresFrequentObservation(
            status: status,
            stableObservations: stableObservations,
            hasRecentActivity: hasRecentActivity,
            isSelectedAttached: isSelectedAttached
        ) else {
            return max(baseInterval, 0)
        }

        let isActive = [.executing, .longRunningShell, .subagents].contains(status)
        let ceiling = isActive ? max(baseInterval, activeMaxInterval) : maxInterval
        let exponent = isActive ? stableObservations - stableObservationThreshold + 1 : stableObservations
        var interval = baseInterval
        for _ in 0..<min(max(exponent, 0), 10) {
            interval = min(ceiling, interval * 2)
            if interval == ceiling { break }
        }
        return min(interval, ceiling)
    }

    public static func requiresFrequentObservation(
        status: SessionStatus,
        stableObservations: Int,
        hasRecentActivity: Bool = false,
        isSelectedAttached: Bool = false
    ) -> Bool {
        if isSelectedAttached || hasRecentActivity { return true }
        switch status {
        case .executing, .longRunningShell, .subagents, .running:
            return stableObservations < stableObservationThreshold
        case .needInput, .asking, .review, .idle, .completed, .failed, .closed:
            return false
        }
    }
}
