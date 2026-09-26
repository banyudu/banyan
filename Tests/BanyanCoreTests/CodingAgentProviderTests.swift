import Testing
@testable import BanyanCore

@Test func providerDetectionAcceptsKnownAgentExecutables() {
    #expect(CodingAgentProvider.detect(in: "codex --ask-for-approval never") == .codex)
    #expect(CodingAgentProvider.detect(in: "/opt/homebrew/bin/claude") == .claude)
    #expect(CodingAgentProvider.detect(in: "deepseek ask for help") == .deepseek)
    #expect(CodingAgentProvider.detect(in: "gemini --model gemini-2.5-pro") == .gemini)
    #expect(CodingAgentProvider.detect(in: "glm ask for help") == .zai)
    #expect(CodingAgentProvider.detect(in: "mimo code") == .xiaomiMiMo)
    #expect(CodingAgentProvider.detect(in: "minimax agent") == .minimax)
    #expect(CodingAgentProvider.detect(in: "opencode") == .opencode)
    #expect(CodingAgentProvider.detect(in: "BANYAN_AGENT_PROVIDER=deepseek opencode") == .deepseek)
}

@Test func providerDetectionRejectsNearMatches() {
    #expect(CodingAgentProvider.detect(in: "my-codex-wrapper") == nil)
    #expect(CodingAgentProvider.detect(in: "") == nil)
}

@Test func providerNamesMapToDefaultAgentExecutables() {
    #expect(CodingAgentProvider(agentName: "codex") == .codex)
    #expect(CodingAgentProvider(agentName: "claude-code") == .claude)
    #expect(CodingAgentProvider(agentName: "glm") == .zai)
    #expect(CodingAgentProvider(agentName: "xiaomi") == .xiaomiMiMo)
    #expect(CodingAgentProvider(agentName: "unknown") == nil)
    #expect(CodingAgentProvider.zai.defaultExecutableName == "glm")
}

@Test func agentLaunchCommandQuotesPromptForShellStartup() {
    let command = AgentLaunchCommand.command(
        provider: .codex,
        prompt: "add John's shortcuts"
    )

    #expect(command == "'codex' 'add John'\\''s shortcuts'")
}

@Test func promptCandidateSkipsCommonAgentFlags() {
    let prompt = CodingAgentProvider.promptCandidate(
        in: #"codex --model gpt-5 --ask-for-approval never "implement sidebar titles""#,
        provider: .codex
    )

    #expect(prompt == "implement sidebar titles")
}

@Test func promptCandidateIgnoresDeepSeekLaunchMarkerAndOpenCodeExecutable() {
    let prompt = CodingAgentProvider.promptCandidate(
        in: "BANYAN_AGENT_PROVIDER=deepseek opencode",
        provider: .deepseek
    )

    #expect(prompt == nil)
}

@Test func promptCandidateSkipsACodexProfileValue() {
    // `codex -p <profile>` (--profile) is launch metadata. Reading the profile
    // as the prompt titled every such session after the profile name.
    #expect(CodingAgentProvider.promptCandidate(in: "codex -p opencode-go", provider: .codex) == nil)
    #expect(CodingAgentProvider.promptCandidate(in: "codex -p luna-fast", provider: .codex) == nil)
    #expect(
        CodingAgentProvider.promptCandidate(
            in: #"codex -p opencode-go --image "/tmp/shot.png" "fix the sidebar""#,
            provider: .codex
        ) == "fix the sidebar"
    )
}

@Test func promptCandidateKeepsClaudePrintModePrompt() {
    // `-p` takes a value for Codex (--profile) and none for Claude (--print), so
    // the two agents cannot share one value-taking flag set.
    #expect(
        CodingAgentProvider.promptCandidate(in: #"claude -p "summarize the diff""#, provider: .claude)
            == "summarize the diff"
    )
}

@Test func promptCandidateSkipsOpenCodeAgentAndSessionValues() {
    #expect(CodingAgentProvider.promptCandidate(in: "opencode --agent muse-spark", provider: .muse) == nil)
    #expect(CodingAgentProvider.promptCandidate(in: "opencode --session ses_abc123", provider: .opencode) == nil)
    #expect(
        CodingAgentProvider.promptCandidate(
            in: "opencode run --agent muse-spark --model opencode-go/muse add tests",
            provider: .opencode
        ) == "add tests"
    )
}

@Test func promptCandidateSkipsAClaudeEffortValue() {
    #expect(
        CodingAgentProvider.promptCandidate(in: "claude --model sonnet --effort max", provider: .claude)
            == nil
    )
}

@Test func promptCandidatePreservesQuotedPromptText() {
    let prompt = CodingAgentProvider.promptCandidate(
        in: AgentLaunchCommand.command(
            provider: .codex,
            prompt: "pull the latest code"
        ),
        provider: .codex
    )

    #expect(prompt == "pull the latest code")
}

@Test func titleGeneratorUsesAgentPromptBeforeGenericSessionID() {
    let title = SessionTitleGenerator.automaticTitle(for: SessionTitleContext(
        id: "session-2",
        baseTitle: "banyan",
        isTitlePinned: false,
        cwd: "/Users/example/dev/yudu/banyan",
        project: "banyan",
        branch: "main",
        command: "deepseek add session icons",
        reportedTitle: nil,
        provider: .deepseek
    ))

    #expect(title == "add session icons")
}

@Test func titleGeneratorUsesFirstPromptSentence() {
    let title = SessionTitleGenerator.automaticTitle(for: SessionTitleContext(
        id: "session-2",
        baseTitle: "banyan",
        isTitlePinned: false,
        cwd: "/Users/example/dev/yudu/banyan",
        project: "banyan",
        branch: "main",
        command: AgentLaunchCommand.command(
            provider: .claude,
            prompt: "pull the latest code. Then run tests and summarize the result."
        ),
        reportedTitle: nil,
        provider: .claude
    ))

    #expect(title == "pull the latest code.")
}

@Test func titleGeneratorIgnoresACodexProfileNameAsThePrompt() {
    let title = SessionTitleGenerator.automaticTitle(for: SessionTitleContext(
        id: "session-7",
        baseTitle: "banyan",
        isTitlePinned: false,
        cwd: "/Users/example/dev/yudu/banyan",
        project: "banyan",
        branch: "main",
        command: "codex -p opencode-go",
        reportedTitle: nil,
        provider: .codex
    ))

    #expect(title == "Codex session-7")
}

@Test func titleGeneratorUsesCompactProviderAndIDWhenPromptIsMissing() {
    let title = SessionTitleGenerator.automaticTitle(for: SessionTitleContext(
        id: "session-2",
        baseTitle: "banyan",
        isTitlePinned: false,
        cwd: "/Users/example/dev/yudu/banyan",
        project: "banyan",
        branch: "main",
        command: "codex --model gpt-5",
        reportedTitle: nil,
        provider: .codex
    ))

    #expect(title == "Codex session-2")
}
