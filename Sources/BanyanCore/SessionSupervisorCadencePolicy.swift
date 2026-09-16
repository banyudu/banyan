import Foundation

public enum SupervisorThermalState: Sendable {
    case nominal
    case fair
    case serious
    case critical
}

/// Calculates supervisor polling cadence without depending on a UI framework
/// or a platform process-information API.
public enum SessionSupervisorCadencePolicy {
    public static func interval(
        isForeground: Bool,
        startedSessionCount: Int,
        activeSessionCount: Int,
        isLowPowerModeEnabled: Bool,
        thermalState: SupervisorThermalState
    ) -> TimeInterval {
        // A tick inspects every started session. Once every session is idle, no
        // user-visible state needs a two-second refresh; terminal output still
        // updates an attached session immediately. Keep the faster cadence only
        // while the last observation found active work.
        let hasActiveWork = activeSessionCount > 0
        var interval: TimeInterval
        if isForeground {
            interval = hasActiveWork ? 2.0 : 6.0
        } else {
            interval = hasActiveWork ? 6.0 : 15.0
        }

        // Stretch with fleet size. A fleet with live work keeps the original 3x
        // ceiling, so nothing about executing-session freshness changes. A fleet
        // where nothing is executing has nothing to transition between ticks —
        // only an executing session reaches `needInput` on its own — so its
        // cadence can keep growing instead of flattening out at 24 sessions and
        // leaving cost to grow linearly from there.
        if startedSessionCount > 8 {
            let scale = Double(startedSessionCount) / 8.0
            interval *= min(hasActiveWork ? 3.0 : 8.0, scale)
        }
        if isLowPowerModeEnabled {
            interval *= 2.0
        }
        switch thermalState {
        case .serious, .critical:
            interval *= 3.0
        case .fair:
            interval *= 1.5
        case .nominal:
            break
        }
        return min(interval, ceiling(isForeground: isForeground, hasActiveWork: hasActiveWork))
    }

    /// The longest a tick may be deferred. Foreground and active-work fleets keep
    /// the original 30s bound so a status dot the user can see never goes stale
    /// for longer than it does today; a backgrounded, fully quiet fleet may sleep
    /// much longer, because the app is not on screen and nothing in it is moving.
    private static func ceiling(isForeground: Bool, hasActiveWork: Bool) -> TimeInterval {
        isForeground || hasActiveWork ? 30.0 : 120.0
    }
}
