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

@Test func agentSessionHistoryBuildsOpencodeResumeCommands() {
    // All opencode-backed providers share `opencode --session`. Previously this
    // returned nil, so Recover re-ran the launch command and every opencode
    // session came back as a blank new session.
    for provider in [CodingAgentProvider.opencode, .deepseek, .hunyuan, .muse, .qwen] {
        #expect(
            AgentSessionHistory.resumeCommand(
                provider: provider,
                sourceID: "ses_abc123",
                cwd: "/tmp/project"
            ) == "'opencode' '--session' 'ses_abc123'",
            "provider \(provider) should resume via opencode --session"
        )
    }
    #expect(
        AgentSessionHistory.resumeCommand(
            provider: .gemini,
            sourceID: "abc",
            cwd: "/tmp"
        ) == nil
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
