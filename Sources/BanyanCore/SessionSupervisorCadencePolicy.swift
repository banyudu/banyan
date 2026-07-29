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
        isLowPowerModeEnabled: Bool,
        thermalState: SupervisorThermalState
    ) -> TimeInterval {
        var interval: TimeInterval = isForeground ? 2.0 : 6.0

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
