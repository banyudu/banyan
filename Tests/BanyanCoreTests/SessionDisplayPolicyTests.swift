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

@Test func displayPolicyHidesLaunchedAgentForBareRunningShells() {
    #expect(SessionDisplayPolicy.displayAgentProvider(
        status: .running,
        command: "codex",
        detectedProvider: .codex
    ) == nil)
    #expect(SessionDisplayPolicy.displayAgentProvider(
        status: .needInput,
        command: "codex",
        detectedProvider: .codex
    ) == .codex)
}
