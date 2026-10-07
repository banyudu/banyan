import Testing
@testable import BanyanCore

@Test func supervisorBackoffGrowsOnlyAfterQuietObservations() {
    #expect(SessionSupervisorBackoffPolicy.interval(
        baseInterval: 6,
        status: .needInput,
        stableObservations: 0
    ) == 6)
    #expect(SessionSupervisorBackoffPolicy.interval(
        baseInterval: 6,
        status: .needInput,
        stableObservations: 1
    ) == 12)
    #expect(SessionSupervisorBackoffPolicy.interval(
        baseInterval: 6,
        status: .needInput,
        stableObservations: 3
    ) == 48)
}

@Test func supervisorBackoffCapsAtOneHour() {
    #expect(SessionSupervisorBackoffPolicy.interval(
        baseInterval: 30,
        status: .idle,
        stableObservations: 10
    ) == SessionSupervisorBackoffPolicy.maxInterval)
}

@Test func supervisorBackoffBoundsUnchangedActiveWork() {
    for status in [SessionStatus.executing, .longRunningShell, .subagents] {
        #expect(!SessionSupervisorBackoffPolicy.requiresFrequentObservation(
            status: status,
            stableObservations: 100
        ))
        #expect(SessionSupervisorBackoffPolicy.interval(
            baseInterval: 6,
            status: status,
            stableObservations: 100
        ) == SessionSupervisorBackoffPolicy.activeMaxInterval)
    }
}

@Test func runningSessionsEnterBackoffAfterSeveralStableObservations() {
    #expect(SessionSupervisorBackoffPolicy.requiresFrequentObservation(
        status: .running,
        stableObservations: 2
    ))
    #expect(!SessionSupervisorBackoffPolicy.requiresFrequentObservation(
        status: .running,
        stableObservations: 3
    ))
}

@Test func supervisorBackoffReopensFastWindowForOutputOrSelection() {
    for status in [SessionStatus.executing, .longRunningShell, .subagents, .needInput] {
        #expect(SessionSupervisorBackoffPolicy.interval(
            baseInterval: 2, status: status, stableObservations: 10, hasRecentActivity: true
        ) == 2)
        #expect(SessionSupervisorBackoffPolicy.interval(
            baseInterval: 2, status: status, stableObservations: 10, isSelectedAttached: true
        ) == 2)
    }
    // Power/thermal constraints can already exceed the active-work ceiling.
    #expect(SessionSupervisorBackoffPolicy.interval(
        baseInterval: 180, status: .executing, stableObservations: 10
    ) == 180)
}
