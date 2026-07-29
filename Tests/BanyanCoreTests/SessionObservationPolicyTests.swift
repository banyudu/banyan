import Testing
@testable import BanyanCore

private func observation(
    id: String = "session",
    status: SessionStatus = .running,
    tone: SessionTone = .blue,
    provider: CodingAgentProvider? = .codex,
    currentPath: String? = "/tmp"
) -> SessionStatusObservation {
    SessionStatusObservation(
        id: id,
        status: status,
        tone: tone,
        provider: provider,
        currentPath: currentPath
    )
}

@Test func observationPolicyRejectsClosedAndUnchangedSessions() {
    #expect(SessionObservationPolicy.reconcile(
        currentStatus: .closed,
        currentTone: .blue,
        currentProvider: .codex,
        currentPath: "/tmp",
        observation: observation()
    ) == nil)
    #expect(SessionObservationPolicy.reconcile(
        currentStatus: .running,
        currentTone: .blue,
        currentProvider: .codex,
        currentPath: "/tmp",
        observation: observation()
    ) == nil)
}

@Test func observationPolicyIdentifiesProviderPathAndRuntimeChanges() {
    let reconciliation = SessionObservationPolicy.reconcile(
        currentStatus: .running,
        currentTone: .blue,
        currentProvider: .codex,
        currentPath: "/tmp",
        observation: observation(status: .asking, tone: .yellow, provider: .claude, currentPath: "/work")
    )

    #expect(reconciliation?.providerChanged == true)
    #expect(reconciliation?.currentPathChanged == true)
    #expect(reconciliation?.runtimeStateChanged == true)
}

@Test func observationPolicyTreatsMissingPathAsNoPathChange() {
    let reconciliation = SessionObservationPolicy.reconcile(
        currentStatus: .running,
        currentTone: .blue,
        currentProvider: .codex,
        currentPath: "/tmp",
        observation: observation(currentPath: nil)
    )

    #expect(reconciliation == nil)
}
