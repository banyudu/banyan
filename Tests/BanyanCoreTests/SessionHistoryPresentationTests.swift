import Testing
import Foundation
@testable import BanyanCore

@Test func historyPresentationUsesSharedHistoryLimits() {
    #expect(SessionHistoryPresentation.sidebarBrowseLimit == 30)
    #expect(SessionHistoryPresentation.sidebarSearchLimit == 100)
    #expect(SessionHistoryPresentation.recoveryImportLimit == 100)
}

@Test func historyPresentationBuildsAndFiltersSidebarTitles() {
    let title = SessionHistoryPresentation.sidebarTitle(
        projectName: "worktree",
        displayTitle: "Fix provider icon",
        issueID: "task-601"
    )

    #expect(title == "TASK-601 · Fix provider icon")
    #expect(SessionHistoryPresentation.matchesFilter(title: title, query: "provider task-601"))
    #expect(!SessionHistoryPresentation.matchesFilter(title: title, query: "codex"))
}

@Test func historyPresentationDoesNotDuplicateExistingIssuePrefix() {
    #expect(SessionHistoryPresentation.sidebarTitle(
        projectName: "worktree",
        displayTitle: "TASK-601 · Fix provider icon",
        issueID: "task-601"
    ) == "TASK-601 · Fix provider icon")
}

@Test func historyPresentationBuildsSortedFilteredSidebarEntries() {
    let candidates = [
        SessionHistorySidebarCandidate(
            id: "older",
            projectName: "worktree",
            displayTitle: "Old task",
            issueID: "eng-1",
            updatedAt: .init(timeIntervalSince1970: 100)
        ),
        SessionHistorySidebarCandidate(
            id: "newer",
            projectName: "worktree",
            displayTitle: "Provider icon",
            issueID: "eng-2",
            updatedAt: .init(timeIntervalSince1970: 200)
        )
    ]

    #expect(SessionHistoryPresentation.sidebarEntries(from: candidates, query: "provider") == [
        SessionHistorySidebarEntry(id: "newer", title: "ENG-2 · Provider icon")
    ])
    #expect(SessionHistoryPresentation.sidebarEntries(from: candidates, query: "").map(\.id) == ["newer", "older"])
}

@Test func historyPresentationFindsSortedStaleTmuxSessions() {
    #expect(SessionHistoryPresentation.staleTmuxSessionNames(
        liveSessionNames: ["banyan-z", "banyan-a", "banyan-live"],
        persistedSessionNames: ["banyan-live"]
    ) == ["banyan-a", "banyan-z"])
}
