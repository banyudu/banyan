import Testing
@testable import BanyanCore

@Test func supervisorCadenceSlowsForBackgroundLoadAndThermalPressure() {
    #expect(SessionSupervisorCadencePolicy.interval(
        activityLevel: .active,
        startedSessionCount: 0,
        activeSessionCount: 0,
        isLowPowerModeEnabled: false,
        thermalState: .nominal
    ) == 6.0)
    #expect(SessionSupervisorCadencePolicy.interval(
        activityLevel: .backgroundVisible,
        startedSessionCount: 8,
        activeSessionCount: 2,
        isLowPowerModeEnabled: true,
        thermalState: .fair
    ) == 18.0)
}

@Test func supervisorCadenceIsCappedWhileVisible() {
    // Visible ceilings bound every on-screen case no matter the fleet size,
    // thermal pressure, or power mode. Off-screen quiet fleets stretch to the
    // hidden ceiling instead (see supervisorCadenceSeparatesNotFrontmostFromNotVisible).
    #expect(SessionSupervisorCadencePolicy.interval(
        activityLevel: .backgroundVisible,
        startedSessionCount: 100,
        activeSessionCount: 0,
        isLowPowerModeEnabled: true,
        thermalState: .critical
    ) == 30.0)
    // Live work, or a window the user is looking at, keeps the original bound.
    #expect(SessionSupervisorCadencePolicy.interval(
        activityLevel: .backgroundVisible,
        startedSessionCount: 100,
        activeSessionCount: 4,
        isLowPowerModeEnabled: true,
        thermalState: .critical
    ) == 30.0)
    #expect(SessionSupervisorCadencePolicy.interval(
        activityLevel: .active,
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
    // A quiet on-screen fleet stretches past the old 3x flattening point up to
    // the visible ceiling: 6x5 would be 30 and 15x5 would be 75, both bounded
    // by the 30s dots-must-stay-honest cap.
    #expect(SessionSupervisorCadencePolicy.interval(
        activityLevel: .active,
        startedSessionCount: 40,
        activeSessionCount: 0,
        isLowPowerModeEnabled: false,
        thermalState: .nominal
    ) == 30.0)
    #expect(SessionSupervisorCadencePolicy.interval(
        activityLevel: .backgroundVisible,
        startedSessionCount: 40,
        activeSessionCount: 0,
        isLowPowerModeEnabled: false,
        thermalState: .nominal
    ) == 30.0)

    for count in [16, 24, 40, 100] {
        #expect(SessionSupervisorCadencePolicy.interval(
            activityLevel: .active,
            startedSessionCount: count,
            activeSessionCount: 1,
            isLowPowerModeEnabled: false,
            thermalState: .nominal
        ) == min(6.0, 2.0 * Double(count) / 8.0))
    }
}

@Test func supervisorCadenceKeepsActiveForegroundSessionsResponsive() {
    #expect(SessionSupervisorCadencePolicy.interval(
        activityLevel: .active,
        startedSessionCount: 3,
        activeSessionCount: 1,
        isLowPowerModeEnabled: false,
        thermalState: .nominal
    ) == 2.0)
}

/// An on-screen window behind another app still shows status dots, so it keeps
/// the visible cadence. Only losing the last visible window unlocks the slow one.
@Test func supervisorCadenceSeparatesNotFrontmostFromNotVisible() {
    #expect(SessionSupervisorCadencePolicy.interval(
        activityLevel: .backgroundVisible,
        startedSessionCount: 4,
        activeSessionCount: 0,
        isLowPowerModeEnabled: false,
        thermalState: .nominal
    ) == 15.0)
    #expect(SessionSupervisorCadencePolicy.interval(
        activityLevel: .hidden,
        startedSessionCount: 4,
        activeSessionCount: 0,
        isLowPowerModeEnabled: false,
        thermalState: .nominal
    ) == 300.0)
}

/// An executing agent can reach `needInput` on its own, so a hidden app still
/// checks every half minute to keep the notification honest. An idle one cannot
/// change without the user, so it stretches to the ceiling.
@Test func supervisorCadenceKeepsHiddenExecutingSessionsNotifiable() {
    #expect(SessionSupervisorCadencePolicy.interval(
        activityLevel: .hidden,
        startedSessionCount: 48,
        activeSessionCount: 8,
        isLowPowerModeEnabled: false,
        thermalState: .nominal
    ) == 30.0)
}

/// The session-count multiplier flattens spikes in a fast cadence; at half a
/// minute there is no spike to flatten, and applying it would only delay
/// notifications on a large workspace.
@Test func supervisorCadenceIgnoresSessionCountWhileHidden() {
    let small = SessionSupervisorCadencePolicy.interval(
        activityLevel: .hidden,
        startedSessionCount: 2,
        activeSessionCount: 1,
        isLowPowerModeEnabled: false,
        thermalState: .nominal
    )
    let large = SessionSupervisorCadencePolicy.interval(
        activityLevel: .hidden,
        startedSessionCount: 200,
        activeSessionCount: 1,
        isLowPowerModeEnabled: false,
        thermalState: .nominal
    )
    #expect(small == large)
}

@Test func supervisorCadenceIsCappedWhileHidden() {
    // Idle and hidden already starts at the ceiling, so every multiplier clamps.
    #expect(SessionSupervisorCadencePolicy.interval(
        activityLevel: .hidden,
        startedSessionCount: 100,
        activeSessionCount: 0,
        isLowPowerModeEnabled: true,
        thermalState: .critical
    ) == 300.0)
    // An executing agent keeps its own base, stretched but still under the ceiling.
    #expect(SessionSupervisorCadencePolicy.interval(
        activityLevel: .hidden,
        startedSessionCount: 100,
        activeSessionCount: 1,
        isLowPowerModeEnabled: true,
        thermalState: .critical
    ) == 180.0)
}

/// Low Power Mode still stretches the hidden cadence, up to the same ceiling.
@Test func supervisorCadenceRespectsLowPowerModeWhileHidden() {
    #expect(SessionSupervisorCadencePolicy.interval(
        activityLevel: .hidden,
        startedSessionCount: 4,
        activeSessionCount: 1,
        isLowPowerModeEnabled: true,
        thermalState: .nominal
    ) == 60.0)
}
