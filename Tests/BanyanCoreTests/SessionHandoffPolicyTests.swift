import Testing
@testable import BanyanCore

@Test func handoffPolicyAllowsIdleAgentWorktreesOnFeatureBranches() {
    #expect(SessionHandoffPolicy.canDispatch(
        isImportedHistory: false,
        provider: .codex,
        status: .needInput,
        isGitWorktree: true,
        branch: "feature/session-tui",
        isDefaultBranch: false
    ))
}

@Test func handoffCommandDefaultsToHomeBinWhenExecutable() {
    let path = SessionHandoffPolicy.commandPath(
        environment: [:],
        homeDirectory: "/Users/dev",
        isExecutableFile: { $0 == "/Users/dev/bin/handoff" }
    )
    #expect(path == "/Users/dev/bin/handoff")
}

@Test func handoffCommandIsNilWhenNothingInstalled() {
    let path = SessionHandoffPolicy.commandPath(
        environment: [:],
        homeDirectory: "/Users/dev",
        isExecutableFile: { _ in false }
    )
    #expect(path == nil)
}

@Test func handoffCommandHonorsEnvironmentOverride() {
    let path = SessionHandoffPolicy.commandPath(
        environment: [SessionHandoffPolicy.commandEnvironmentKey: "/opt/tools/handoff"],
        homeDirectory: "/Users/dev",
        isExecutableFile: { $0 == "/opt/tools/handoff" }
    )
    #expect(path == "/opt/tools/handoff")
}

@Test func handoffCommandExpandsTildeInOverride() {
    let path = SessionHandoffPolicy.commandPath(
        environment: [SessionHandoffPolicy.commandEnvironmentKey: "~/tools/handoff"],
        homeDirectory: "/Users/dev",
        isExecutableFile: { $0 == "/Users/dev/tools/handoff" }
    )
    #expect(path == "/Users/dev/tools/handoff")
}

@Test func handoffCommandIgnoresBlankOverrideAndNonExecutableTarget() {
    let blankOverride = SessionHandoffPolicy.commandPath(
        environment: [SessionHandoffPolicy.commandEnvironmentKey: "  "],
        homeDirectory: "/Users/dev",
        isExecutableFile: { $0 == "/Users/dev/bin/handoff" }
    )
    #expect(blankOverride == "/Users/dev/bin/handoff")

    let nonExecutable = SessionHandoffPolicy.commandPath(
        environment: [SessionHandoffPolicy.commandEnvironmentKey: "/opt/tools/handoff"],
        homeDirectory: "/Users/dev",
        isExecutableFile: { _ in false }
    )
    #expect(nonExecutable == nil)
}

@Test func handoffPolicyRejectsUnsupportedSessionContexts() {
    #expect(!SessionHandoffPolicy.canDispatch(
        isImportedHistory: true,
        provider: .codex,
        status: .needInput,
        isGitWorktree: true,
        branch: "feature/session-tui",
        isDefaultBranch: false
    ))
    #expect(!SessionHandoffPolicy.canDispatch(
        isImportedHistory: false,
        provider: .codex,
        status: .executing,
        isGitWorktree: true,
        branch: "feature/session-tui",
        isDefaultBranch: false
    ))
    #expect(!SessionHandoffPolicy.canDispatch(
        isImportedHistory: false,
        provider: .codex,
        status: .needInput,
        isGitWorktree: true,
        branch: "main",
        isDefaultBranch: true
    ))
}

@Test func handoffFailureNoticeCarriesTheCommandOutput() {
    let notice = SessionHandoffPolicy.dispatchFailureNotice(
        exitStatus: 127,
        output: "handoff: /Users/dev/.agents/bin/handoff not found or not executable\n"
    )
    #expect(notice == """
    Handoff could not be started (exit 127). The session was restored.

    handoff: /Users/dev/.agents/bin/handoff not found or not executable
    """)
}

@Test func handoffFailureNoticeKeepsTheTailAndStripsANSI() {
    let output = (1...20).map { "line \($0)" }.joined(separator: "\n")
        + "\n\u{001B}[31mError: no PR detected\u{001B}[0m\n"
    let notice = SessionHandoffPolicy.dispatchFailureNotice(exitStatus: 1, output: output)
    #expect(notice.hasSuffix("Error: no PR detected"))
    #expect(!notice.contains("line 14"))
    #expect(notice.contains("line 16"))
    #expect(!notice.contains("\u{001B}"))
}

@Test func handoffFailureNoticeOmitsDetailWhenCommandWasSilent() {
    let notice = SessionHandoffPolicy.dispatchFailureNotice(exitStatus: 1, output: "   \n\n")
    #expect(notice == "Handoff could not be started (exit 1). The session was restored.")
}

@Test func handoffFailureNoticeReportsLaunchErrorsWithoutAnExitStatus() {
    let notice = SessionHandoffPolicy.dispatchFailureNotice(
        exitStatus: nil,
        output: "The file “handoff” doesn’t exist."
    )
    #expect(notice == """
    Handoff could not be started. The session was restored.

    The file “handoff” doesn’t exist.
    """)
}
