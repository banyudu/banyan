import Testing
@testable import BanyanCore

@Test func displayPolicyPrefersPinnedThenReportedThenGeneratedTitles() {
    #expect(SessionDisplayPolicy.displayTitle(
        title: "Pinned",
        isTitlePinned: true,
        reportedTitle: "Reported",
        generatedTitle: "Generated",
        cwd: "/tmp/project",
        homeDirectory: "/home/test",
        detectedProvider: .codex,
        command: "codex"
    ) == "Pinned")
    #expect(SessionDisplayPolicy.displayTitle(
        title: "project",
        isTitlePinned: false,
        reportedTitle: "Reported",
        generatedTitle: "Generated",
        cwd: "/tmp/project",
        homeDirectory: "/home/test",
        detectedProvider: .codex,
        command: "codex"
    ) == "Reported")
    #expect(SessionDisplayPolicy.displayTitle(
        title: "project",
        isTitlePinned: false,
        reportedTitle: nil,
        generatedTitle: "Generated",
        cwd: "/tmp/project",
        homeDirectory: "/home/test",
        detectedProvider: nil,
        command: ""
    ) == "Generated")
}

@Test func displayPolicyIgnoresGenericProviderSessionReportedTitles() {
    #expect(SessionDisplayPolicy.displayTitle(
        title: "project",
        isTitlePinned: false,
        reportedTitle: "Claude session-83",
        generatedTitle: "Fix the sidebar title",
        cwd: "/tmp/project",
        homeDirectory: "/home/test",
        detectedProvider: .claude,
        command: "claude"
    ) == "Fix the sidebar title")
}

@Test func displayPolicyKeepsKnownProviderDuringStartup() {
    #expect(SessionDisplayPolicy.displayAgentProvider(
        status: .running,
        command: "codex",
        detectedProvider: .codex
    ) == .codex)
    #expect(SessionDisplayPolicy.displayAgentProvider(
        status: .running,
        command: "BANYAN_AGENT_PROVIDER=deepseek opencode",
        detectedProvider: .deepseek
    ) == .deepseek)
}

@Test func displayPolicyHidesBareRunningShellAfterAgentClears() {
    #expect(SessionDisplayPolicy.displayAgentProvider(
        status: .running,
        command: "codex",
        detectedProvider: nil
    ) == nil)
    #expect(SessionDisplayPolicy.displayAgentProvider(
        status: .needInput,
        command: "codex",
        detectedProvider: .codex
    ) == .codex)
}
