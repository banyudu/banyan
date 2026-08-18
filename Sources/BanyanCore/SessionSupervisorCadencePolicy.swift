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
        // A tick shells out to tmux for every started session. Once every session
        // is idle, no user-visible state needs a two-second refresh; terminal
        // output still updates an attached session immediately. Keep the faster
        // cadence only while the last observation found active work.
        var interval: TimeInterval
        if isForeground {
            interval = activeSessionCount > 0 ? 2.0 : 6.0
        } else {
            interval = activeSessionCount > 0 ? 6.0 : 15.0
        }

        if startedSessionCount > 8 {
            interval *= min(3.0, Double(startedSessionCount) / 8.0)
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
        return min(interval, 30.0)
    }
}
