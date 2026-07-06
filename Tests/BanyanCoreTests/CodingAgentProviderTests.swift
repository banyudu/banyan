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
        cwd: "/Users/banyudu/dev/yudu/banyan",
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
        cwd: "/Users/banyudu/dev/yudu/banyan",
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

@Test func titleGeneratorUsesProviderProjectAndIDWhenPromptIsMissing() {
    let title = SessionTitleGenerator.automaticTitle(for: SessionTitleContext(
        id: "session-2",
        baseTitle: "banyan",
        isTitlePinned: false,
        cwd: "/Users/banyudu/dev/yudu/banyan",
        project: "banyan",
        branch: "main",
        command: "codex --model gpt-5",
        reportedTitle: nil,
        provider: .codex
    ))

    #expect(title == "Codex · banyan · main · session-2")
}
