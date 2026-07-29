import Testing
@testable import BanyanCore

@Test func supervisorCadenceSlowsForBackgroundLoadAndThermalPressure() {
    #expect(SessionSupervisorCadencePolicy.interval(
        isForeground: true,
        startedSessionCount: 0,
        isLowPowerModeEnabled: false,
        thermalState: .nominal
    ) == 2.0)
    #expect(SessionSupervisorCadencePolicy.interval(
        isForeground: false,
        startedSessionCount: 8,
        isLowPowerModeEnabled: true,
        thermalState: .fair
    ) == 18.0)
}

@Test func supervisorCadenceIsCapped() {
    #expect(SessionSupervisorCadencePolicy.interval(
        isForeground: false,
        startedSessionCount: 100,
        isLowPowerModeEnabled: true,
        thermalState: .critical
    ) == 30.0)
}
