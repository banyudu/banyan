import Foundation

public enum SupervisorThermalState: Sendable {
    case nominal
    case fair
    case serious
    case critical
}

/// How much of the app the user can actually see, which is what decides how
/// fresh its polled state has to be.
///
/// "Frontmost or not" is too coarse a split to throttle on: an app sitting on
/// screen behind another one still has to keep its status dots honest, while an
/// app that is hidden, miniaturized, or completely covered draws nothing anyone
/// can read. Only the second state is free to slow down.
public enum SupervisorActivityLevel: Sendable {
    /// Frontmost application.
    case active
    /// Not frontmost, but at least one window is on screen and not fully covered.
    case backgroundVisible
    /// Hidden, miniaturized, or every window occluded — nothing Banyan draws is visible.
    case hidden
}

/// Calculates supervisor polling cadence without depending on a UI framework
/// or a platform process-information API.
public enum SessionSupervisorCadencePolicy {
    /// Ceiling while any part of the UI is on screen. Past this a status dot
    /// reads as broken rather than merely late.
    public static let visibleMaxInterval: TimeInterval = 30.0

    /// Ceiling once nothing is on screen. The tick is the only thing that turns
    /// an unattached session's new state into a notification, so this doubles as
    /// the worst-case attention latency for a session the user has never opened.
    /// Attached sessions are unaffected: their status signals arrive on the PTY
    /// as the agent writes them, whatever the app is doing.
    public static let hiddenMaxInterval: TimeInterval = 300.0

    public static func interval(
        activityLevel: SupervisorActivityLevel,
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
        let maxInterval: TimeInterval
        switch activityLevel {
        case .active:
            interval = activeSessionCount > 0 ? 2.0 : 6.0
            maxInterval = visibleMaxInterval
        case .backgroundVisible:
            interval = activeSessionCount > 0 ? 6.0 : 15.0
            maxInterval = visibleMaxInterval
        case .hidden:
            // Nothing is on screen, so the only reason left to look is to raise a
            // notification. An idle agent cannot change without the user, so that
            // case stretches to the ceiling; an executing one can finish at any
            // moment and keeps a half-minute check.
            interval = activeSessionCount > 0 ? 30.0 : hiddenMaxInterval
            maxInterval = hiddenMaxInterval
        }

        // Scaling with the session count exists to stop a large workspace from
        // spiking a two-second cadence. There is no spike to flatten once the
        // base interval is already half a minute, and stretching it further would
        // only delay notifications, so it applies to on-screen cadences alone.
        if activityLevel != .hidden, startedSessionCount > 8 {
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
        return min(interval, maxInterval)
    }
}
