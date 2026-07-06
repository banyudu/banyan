import Testing
@testable import Banyan

@Test func restoreKeepsClosedSessionsHiddenEvenWhenBackingTmuxSessionExists() {
    #expect(SessionStore.restoredStatus(snapshotStatus: .closed, backingSessionExists: true) == .closed)
}

@Test func restorePreservesActiveSessionStatus() {
    #expect(SessionStore.restoredStatus(snapshotStatus: .running, backingSessionExists: true) == .running)
    #expect(SessionStore.restoredStatus(snapshotStatus: .needInput, backingSessionExists: false) == .needInput)
}

@Test func historySidebarTitleUsesIssueIDInsteadOfWorktreeName() {
    let title = SessionStore.historySidebarTitle(
        projectName: "yudu-eng-6061-32baaf",
        displayTitle: "Personal coding run",
        issueID: "ENG-6061"
    )

    #expect(title == "ENG-6061 · Personal coding run")
}

@Test func historySidebarTitleDoesNotDuplicateExistingIssuePrefix() {
    let title = SessionStore.historySidebarTitle(
        projectName: "yudu-eng-6061-32baaf",
        displayTitle: "ENG-6061 Personal coding run",
        issueID: "ENG-6061"
    )

    #expect(title == "ENG-6061 Personal coding run")
}

@Test func historySidebarTitleKeepsProjectNameWithoutIssueID() {
    let title = SessionStore.historySidebarTitle(
        projectName: "banyan",
        displayTitle: "Fix sidebar grouping",
        issueID: nil
    )

    #expect(title == "banyan · Fix sidebar grouping")
}
