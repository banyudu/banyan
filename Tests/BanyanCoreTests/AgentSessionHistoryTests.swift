import Testing
@testable import BanyanCore

@Test func agentSessionHistoryBuildsPortableResumeCommands() {
    #expect(
        AgentSessionHistory.resumeCommand(
            provider: .codex,
            sourceID: "thread-1",
            cwd: "/tmp/project",
            prompt: "fix the parser"
        ) == "'codex' 'resume' '-C' '/tmp/project' 'thread-1' 'fix the parser'"
    )
    #expect(
        AgentSessionHistory.resumeCommand(
            provider: .claude,
            sourceID: "session-1",
            cwd: "/tmp/project"
        ) == "'claude' '--resume' 'session-1'"
    )
}

@Test func agentSessionHistoryParsesImportedIDs() {
    #expect(
        AgentSessionHistory.sourceID(
            fromImportedSessionID: "history-codex-thread-1",
            provider: .codex
        ) == "thread-1"
    )
    #expect(
        AgentSessionHistory.sourceID(
            fromImportedSessionID: "session-1",
            provider: .claude
        ) == nil
    )
}
