import Testing
@testable import BanyanCore

@Test func restorationPolicyDerivesMissingTmuxNameAndRecovery() {
    let snapshot = SessionSnapshot(
        id: "restore-me",
        tmuxSessionName: nil,
        title: "Shell",
        reportedTitle: nil,
        cwd: "/tmp",
        command: "",
        status: .running,
        tone: .blue,
        createdAt: .init(timeIntervalSince1970: 100),
        updatedAt: .init(timeIntervalSince1970: 100)
    )

    let plan = SessionRestorationPolicy.plan(for: snapshot, liveTmuxSessionNames: [])

    #expect(plan == SessionRestorationPlan(
        tmuxSessionName: "banyan-restore-me",
        status: .running,
        needsRecovery: true
    ))
}

@Test func restorationPolicyDoesNotRecoverTerminalStates() {
    for status in [SessionStatus.closed, .completed, .failed] {
        let snapshot = SessionSnapshot(
            id: "finished",
            tmuxSessionName: "banyan-finished",
            title: "Finished",
            reportedTitle: nil,
            cwd: "/tmp",
            command: "",
            status: status,
            tone: .neutral,
            createdAt: .init(timeIntervalSince1970: 100),
            updatedAt: .init(timeIntervalSince1970: 100)
        )

        #expect(!SessionRestorationPolicy.plan(
            for: snapshot,
            liveTmuxSessionNames: []
        ).needsRecovery)
    }
}
