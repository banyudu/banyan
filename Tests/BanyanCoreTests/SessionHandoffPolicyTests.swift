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
