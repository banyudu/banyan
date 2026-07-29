import Testing
@testable import BanyanCore

@Test func restorationPolicyRequiresManualAttachOnlyForUnstartedRecoveryStates() {
    #expect(SessionRestorationPolicy.needsManualAttach(
        isRestored: true,
        isProcessStarted: false,
        status: .failed,
        needsRecovery: false
    ))
    #expect(SessionRestorationPolicy.needsManualAttach(
        isRestored: true,
        isProcessStarted: false,
        status: .running,
        needsRecovery: true
    ))
    #expect(!SessionRestorationPolicy.needsManualAttach(
        isRestored: true,
        isProcessStarted: true,
        status: .failed,
        needsRecovery: true
    ))
    #expect(!SessionRestorationPolicy.needsManualAttach(
        isRestored: false,
        isProcessStarted: false,
        status: .failed,
        needsRecovery: true
    ))
}

@Test func restorationPolicyRestoresGenericUnpinnedTitlesFromWorkingDirectory() {
    let snapshot = SessionSnapshot(
        id: "restore-me",
        tmuxSessionName: nil,
        title: "shell-2",
        reportedTitle: nil,
        isTitlePinned: false,
        cwd: "/home/yudu/dev/banyan",
        command: "",
        status: .running,
        tone: .blue,
        createdAt: .init(timeIntervalSince1970: 100),
        updatedAt: .init(timeIntervalSince1970: 100),
    )

    #expect(SessionRestorationPolicy.restoredTitle(
        for: snapshot,
        homeDirectory: "/home/yudu"
    ) == "~/dev/banyan")
}

@Test func restorationPolicyPreservesPinnedAndSpecificTitles() {
    let pinned = SessionSnapshot(
        id: "pinned",
        tmuxSessionName: nil,
        title: "shell",
        reportedTitle: nil,
        isTitlePinned: true,
        cwd: "/tmp",
        command: "",
        status: .running,
        tone: .blue,
        createdAt: .init(timeIntervalSince1970: 100),
        updatedAt: .init(timeIntervalSince1970: 100),
    )
    let specific = SessionSnapshot(
        id: "specific",
        tmuxSessionName: nil,
        title: "codex",
        reportedTitle: nil,
        isTitlePinned: false,
        cwd: "/tmp",
        command: "",
        status: .running,
        tone: .blue,
        createdAt: .init(timeIntervalSince1970: 100),
        updatedAt: .init(timeIntervalSince1970: 100),
    )

    #expect(SessionRestorationPolicy.restoredTitle(for: pinned, homeDirectory: "/home/yudu") == "shell")
    #expect(SessionRestorationPolicy.restoredTitle(for: specific, homeDirectory: "/home/yudu") == "codex")
}

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
