import Foundation
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

@Test func promptTitleMatchAfterResetUsesRecentlyUpdatedSession() {
    let base = Date(timeIntervalSince1970: 1_787_500_000)
    let old = ImportedAgentSession(
        id: "history-codex-old",
        provider: .codex,
        sourceID: "old",
        title: "Old title",
        cwd: "/tmp/banyan",
        transcriptURL: URL(fileURLWithPath: "/tmp/old.jsonl"),
        createdAt: base,
        updatedAt: base.addingTimeInterval(30)
    )
    let current = ImportedAgentSession(
        id: "history-codex-current",
        provider: .codex,
        sourceID: "current",
        title: "Updated after clear",
        cwd: "/tmp/banyan",
        transcriptURL: URL(fileURLWithPath: "/tmp/current.jsonl"),
        createdAt: base,
        updatedAt: base.addingTimeInterval(620)
    )

    let match = SessionStore.bestPromptTitleMatch(
        sessionCWD: "/tmp/banyan",
        sessionCreatedAt: base,
        sessionResetAt: base.addingTimeInterval(600),
        provider: .codex,
        in: [old, current]
    )

    #expect(match?.id == "history-codex-current")
}

@Test func promptTitleMatchWithoutResetKeepsCreationWindowBehavior() {
    let base = Date(timeIntervalSince1970: 1_787_500_000)
    let launchMatch = ImportedAgentSession(
        id: "history-codex-launch",
        provider: .codex,
        sourceID: "launch",
        title: "Launch title",
        cwd: "/tmp/banyan",
        transcriptURL: URL(fileURLWithPath: "/tmp/launch.jsonl"),
        createdAt: base.addingTimeInterval(60),
        updatedAt: base.addingTimeInterval(70)
    )
    let later = ImportedAgentSession(
        id: "history-codex-later",
        provider: .codex,
        sourceID: "later",
        title: "Later unrelated title",
        cwd: "/tmp/banyan",
        transcriptURL: URL(fileURLWithPath: "/tmp/later.jsonl"),
        createdAt: base.addingTimeInterval(900),
        updatedAt: base.addingTimeInterval(910)
    )

    let match = SessionStore.bestPromptTitleMatch(
        sessionCWD: "/tmp/banyan",
        sessionCreatedAt: base,
        sessionResetAt: nil,
        provider: .codex,
        in: [later, launchMatch]
    )

    #expect(match?.id == "history-codex-launch")
}
