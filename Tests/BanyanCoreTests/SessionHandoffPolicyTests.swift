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
