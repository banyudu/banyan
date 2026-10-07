import Foundation

/// Shared eligibility rules for reversible freezing and future deeper suspension.
/// Quiet output alone is insufficient: a waiting network request can be mid-turn.
public enum AgentInactivityPolicy {
    public static func permitsSuspension(status: SessionStatus, focused: Bool, visible: Bool,
                                         quietSeconds: TimeInterval, threshold: TimeInterval) -> Bool {
        !focused && !visible && [.idle, .needInput].contains(status)
            && quietSeconds.isFinite && quietSeconds >= threshold
    }

    public static func idleThreshold(minutes: Double, background: Bool, onBattery: Bool,
                                     sessionCount: Int) -> TimeInterval {
        let base = min(120, max(1, minutes.isFinite ? minutes : 10)) * 60
        let scale = (background ? 0.75 : 1) * (onBattery ? 0.75 : 1)
            * (sessionCount >= 8 ? 0.5 : 1)
        return max(60, base * scale)
    }

    /// Reuses supervisor wakeups; no separate repeating timer. CPU must be sampled
    /// because output/focus events cannot tell whether a silent process is busy.
    public static func probeInterval(threshold: TimeInterval) -> TimeInterval {
        min(120, max(15, threshold / 4))
    }
}
