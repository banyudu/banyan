import Testing
@testable import BanyanCore

@Test func historyPresentationBuildsAndFiltersSidebarTitles() {
    let title = SessionHistoryPresentation.sidebarTitle(
        projectName: "worktree",
        displayTitle: "Fix provider icon",
        issueID: "eng-6061"
    )

    #expect(title == "ENG-6061 · Fix provider icon")
    #expect(SessionHistoryPresentation.matchesFilter(title: title, query: "provider eng-6061"))
    #expect(!SessionHistoryPresentation.matchesFilter(title: title, query: "codex"))
}

@Test func historyPresentationDoesNotDuplicateExistingIssuePrefix() {
    #expect(SessionHistoryPresentation.sidebarTitle(
        projectName: "worktree",
        displayTitle: "ENG-6061 · Fix provider icon",
        issueID: "eng-6061"
    ) == "ENG-6061 · Fix provider icon")
}

@Test func historyPresentationFindsSortedStaleTmuxSessions() {
    #expect(SessionHistoryPresentation.staleTmuxSessionNames(
        liveSessionNames: ["banyan-z", "banyan-a", "banyan-live"],
        persistedSessionNames: ["banyan-live"]
    ) == ["banyan-a", "banyan-z"])
}
