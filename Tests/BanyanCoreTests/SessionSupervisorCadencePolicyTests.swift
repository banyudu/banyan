import Testing
@testable import BanyanCore

@Test func supervisorCadenceSlowsForBackgroundLoadAndThermalPressure() {
    #expect(SessionSupervisorCadencePolicy.interval(
        isForeground: true,
        startedSessionCount: 0,
        activeSessionCount: 0,
        isLowPowerModeEnabled: false,
        thermalState: .nominal
    ) == 6.0)
    #expect(SessionSupervisorCadencePolicy.interval(
        isForeground: false,
        startedSessionCount: 8,
        activeSessionCount: 2,
        isLowPowerModeEnabled: true,
        thermalState: .fair
    ) == 18.0)
}

@Test func supervisorCadenceIsCapped() {
    // Backgrounded and entirely quiet: nothing on screen, and nothing that can
    // transition without the user, so the tick may sleep well past the 30s bound
    // the visible cases keep.
    #expect(SessionSupervisorCadencePolicy.interval(
        isForeground: false,
        startedSessionCount: 100,
        activeSessionCount: 0,
        isLowPowerModeEnabled: true,
        thermalState: .critical
    ) == 120.0)
    // Live work, or a window the user is looking at, keeps the original bound.
    #expect(SessionSupervisorCadencePolicy.interval(
        isForeground: false,
        startedSessionCount: 100,
        activeSessionCount: 4,
        isLowPowerModeEnabled: true,
        thermalState: .critical
    ) == 30.0)
    #expect(SessionSupervisorCadencePolicy.interval(
        isForeground: true,
        startedSessionCount: 100,
        activeSessionCount: 0,
        isLowPowerModeEnabled: false,
        thermalState: .nominal
    ) == 30.0)
}

/// Cost per tick used to grow with the fleet while the cadence stopped
/// stretching at 24 sessions. A fleet with live work keeps exactly the cadence it
/// had — the acceptance bar is that active-session freshness does not move — and
/// only a fleet where nothing is executing stretches further.
@Test func supervisorCadenceKeepsStretchingForLargeQuietFleets() {
    #expect(SessionSupervisorCadencePolicy.interval(
        isForeground: true,
        startedSessionCount: 40,
        activeSessionCount: 0,
        isLowPowerModeEnabled: false,
        thermalState: .nominal
    ) == 30.0)
    #expect(SessionSupervisorCadencePolicy.interval(
        isForeground: false,
        startedSessionCount: 40,
        activeSessionCount: 0,
        isLowPowerModeEnabled: false,
        thermalState: .nominal
    ) == 75.0)

    for count in [16, 24, 40, 100] {
        #expect(SessionSupervisorCadencePolicy.interval(
            isForeground: true,
            startedSessionCount: count,
            activeSessionCount: 1,
            isLowPowerModeEnabled: false,
            thermalState: .nominal
        ) == min(6.0, 2.0 * Double(count) / 8.0))
    }
}

@Test func supervisorCadenceKeepsActiveForegroundSessionsResponsive() {
    #expect(SessionSupervisorCadencePolicy.interval(
        isForeground: true,
        startedSessionCount: 3,
        activeSessionCount: 1,
        isLowPowerModeEnabled: false,
        thermalState: .nominal
    ) == 2.0)
}
