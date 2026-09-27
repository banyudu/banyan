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

@Test func codexProfileIsReadFromTheLaunchFormsBanyanAndHumansWrite() {
    #expect(AgentSessionHistory.codexProfile(fromCommand: "codex -p opencode-go") == "opencode-go")
    #expect(AgentSessionHistory.codexProfile(fromCommand: "codex --profile sol resume") == "sol")
    #expect(AgentSessionHistory.codexProfile(fromCommand: "'codex' '-p' 'luna-fast' '-c' 'x=1'") == "luna-fast")
    #expect(AgentSessionHistory.codexProfile(fromCommand: "codex --profile=terra") == "terra")
    #expect(AgentSessionHistory.codexProfile(fromCommand: "codex -p=fast") == "fast")
    // The real shape: a worktree `cd`, a profile, and a prompt file.
    #expect(AgentSessionHistory.codexProfile(
        fromCommand: "cd '/tmp/wt' && codex -p sol -c 'model_reasoning_effort=\"xhigh\"' \"$(cat '/tmp/p.txt')\""
    ) == "sol")
}

@Test func codexProfileIsIgnoredWhereItWouldNotBelongToTheLaunch() {
    // No profile at all, including every non-codex tool.
    #expect(AgentSessionHistory.codexProfile(fromCommand: "codex resume thread-1") == nil)
    #expect(AgentSessionHistory.codexProfile(fromCommand: "claude -p hello") == nil)
    #expect(AgentSessionHistory.codexProfile(fromCommand: nil) == nil)
    #expect(AgentSessionHistory.codexProfile(fromCommand: "") == nil)
    // A `-p` after the subcommand belongs to that subcommand, not the launch.
    #expect(AgentSessionHistory.codexProfile(fromCommand: "codex resume -p thread-1") == nil)
    // Dangling flag is a rejection, not a guess.
    #expect(AgentSessionHistory.codexProfile(fromCommand: "codex -p") == nil)
}

@Test func codexResumeKeepsTheProfileItsConversationWasCreatedUnder() throws {
    // The failure this guards: resume without the profile dies on
    // "Model provider 'opencode-go' not found", and the recovered session is
    // closed again within seconds.
    let resume = try #require(AgentSessionHistory.resumeCommand(
        provider: .codex,
        sourceID: "01a0dd93-248f-7c10-a145-465334f3bc79",
        cwd: "/Users/example/dev/project"
    ))
    #expect(
        AgentSessionHistory.applyingCodexProfile(
            fromCommand: "codex -p opencode-go",
            to: resume
        ) == "'codex' '-p' 'opencode-go' 'resume' '-C' '/Users/example/dev/project' '01a0dd93-248f-7c10-a145-465334f3bc79'"
    )
}

@Test func codexProfileIsNotAppliedWhereItDoesNotBelong() throws {
    let resume = try #require(AgentSessionHistory.resumeCommand(
        provider: .codex,
        sourceID: "thread-1",
        cwd: "/tmp/project"
    ))
    // No previous profile, or a previous command that never had one.
    #expect(AgentSessionHistory.applyingCodexProfile(fromCommand: nil, to: resume) == resume)
    #expect(AgentSessionHistory.applyingCodexProfile(fromCommand: "codex", to: resume) == resume)
    // Already carries one: never add a second.
    let already = "'codex' '-p' 'sol' 'resume' '-C' '/tmp/project' 'thread-1'"
    #expect(
        AgentSessionHistory.applyingCodexProfile(fromCommand: "codex -p fast", to: already) == already
    )
    // Not a plain resume invocation — app-server chains and claude resumes are
    // not ours to re-quote.
    let appServer = "codex app-server start && exec codex --remote unix:///tmp/s.sock resume -C /tmp/p thread-1"
    #expect(AgentSessionHistory.applyingCodexProfile(fromCommand: "codex -p fast", to: appServer) == appServer)
    let claude = "'claude' '--resume' 'session-1'"
    #expect(AgentSessionHistory.applyingCodexProfile(fromCommand: "codex -p fast", to: claude) == claude)
    // A pipeline is refused rather than re-quoted.
    let piped = "codex resume -C /tmp/p thread-1 | tee /tmp/log"
    #expect(AgentSessionHistory.applyingCodexProfile(fromCommand: "codex -p fast", to: piped) == piped)
}
