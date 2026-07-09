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

@MainActor
@Test func importedHistorySessionIgnoresTimestampOnlyUpdates() {
    let base = Date(timeIntervalSince1970: 1_787_500_000)
    let session = BanyanSession(
        id: "history-codex-live",
        title: "Keep history stable",
        cwd: "/tmp/banyan",
        command: "codex",
        status: .completed,
        tone: .neutral,
        historyTranscriptURL: URL(fileURLWithPath: "/tmp/live.jsonl"),
        createdAt: base,
        updatedAt: base,
        isRestored: true,
        theme: .system
    )
    let history = ImportedAgentSession(
        id: "history-codex-live",
        provider: .codex,
        sourceID: "live",
        title: "Keep history stable",
        cwd: "/tmp/banyan",
        transcriptURL: URL(fileURLWithPath: "/tmp/live.jsonl"),
        createdAt: base,
        updatedAt: base.addingTimeInterval(20)
    )

    #expect(SessionStore.importedHistorySession(session, matches: history))
}

@MainActor
@Test func importedHistorySessionDetectsVisibleMetadataChanges() {
    let base = Date(timeIntervalSince1970: 1_787_500_000)
    let session = BanyanSession(
        id: "history-codex-live",
        title: "Old title",
        cwd: "/tmp/banyan",
        command: "codex",
        status: .completed,
        tone: .neutral,
        historyTranscriptURL: URL(fileURLWithPath: "/tmp/live.jsonl"),
        createdAt: base,
        updatedAt: base,
        isRestored: true,
        theme: .system
    )
    let history = ImportedAgentSession(
        id: "history-codex-live",
        provider: .codex,
        sourceID: "live",
        title: "New title",
        cwd: "/tmp/banyan",
        transcriptURL: URL(fileURLWithPath: "/tmp/live.jsonl"),
        createdAt: base,
        updatedAt: base.addingTimeInterval(20)
    )

    #expect(!SessionStore.importedHistorySession(session, matches: history))
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

@Test func promptTitleAssignmentsDoNotReuseOneHistoryTitleForMultipleSessions() {
    let base = Date(timeIntervalSince1970: 1_787_500_000)
    let sessions = [
        LivePromptTitleMatchInput(
            id: "session-a",
            cwd: "/tmp/banyan",
            createdAt: base,
            resetAt: nil,
            provider: .codex
        ),
        LivePromptTitleMatchInput(
            id: "session-b",
            cwd: "/tmp/banyan",
            createdAt: base.addingTimeInterval(10),
            resetAt: nil,
            provider: .codex
        )
    ]
    let imported = [
        ImportedAgentSession(
            id: "history-codex-only",
            provider: .codex,
            sourceID: "only",
            title: "One imported prompt",
            cwd: "/tmp/banyan",
            transcriptURL: URL(fileURLWithPath: "/tmp/only.jsonl"),
            createdAt: base.addingTimeInterval(5),
            updatedAt: base.addingTimeInterval(6)
        )
    ]

    let matches = SessionStore.bestPromptTitleAssignments(
        for: sessions,
        in: imported
    )

    #expect(matches.count == 1)
    #expect(Set(matches.values.map(\.id)) == ["history-codex-only"])
}

@Test func promptTitleAssignmentsPreferNearestOneToOneMatches() {
    let base = Date(timeIntervalSince1970: 1_787_500_000)
    let sessions = [
        LivePromptTitleMatchInput(
            id: "session-a",
            cwd: "/tmp/banyan",
            createdAt: base,
            resetAt: nil,
            provider: .codex
        ),
        LivePromptTitleMatchInput(
            id: "session-b",
            cwd: "/tmp/banyan",
            createdAt: base.addingTimeInterval(70),
            resetAt: nil,
            provider: .codex
        )
    ]
    let imported = [
        ImportedAgentSession(
            id: "history-codex-a",
            provider: .codex,
            sourceID: "a",
            title: "First imported prompt",
            cwd: "/tmp/banyan",
            transcriptURL: URL(fileURLWithPath: "/tmp/a.jsonl"),
            createdAt: base.addingTimeInterval(2),
            updatedAt: base.addingTimeInterval(3)
        ),
        ImportedAgentSession(
            id: "history-codex-b",
            provider: .codex,
            sourceID: "b",
            title: "Second imported prompt",
            cwd: "/tmp/banyan",
            transcriptURL: URL(fileURLWithPath: "/tmp/b.jsonl"),
            createdAt: base.addingTimeInterval(73),
            updatedAt: base.addingTimeInterval(74)
        )
    ]

    let matches = SessionStore.bestPromptTitleAssignments(
        for: sessions,
        in: imported
    )

    #expect(matches["session-a"]?.id == "history-codex-a")
    #expect(matches["session-b"]?.id == "history-codex-b")
}

@Test func promptTitleAssignmentsAfterResetPreferNewestUpdatedHistory() {
    let base = Date(timeIntervalSince1970: 1_787_500_000)
    let sessions = [
        LivePromptTitleMatchInput(
            id: "session-a",
            cwd: "/tmp/banyan",
            createdAt: base,
            resetAt: base.addingTimeInterval(600),
            provider: .codex
        )
    ]
    let imported = [
        ImportedAgentSession(
            id: "history-codex-old",
            provider: .codex,
            sourceID: "old",
            title: "Old prompt",
            cwd: "/tmp/banyan",
            transcriptURL: URL(fileURLWithPath: "/tmp/old.jsonl"),
            createdAt: base,
            updatedAt: base.addingTimeInterval(605)
        ),
        ImportedAgentSession(
            id: "history-codex-new",
            provider: .codex,
            sourceID: "new",
            title: "Newest prompt",
            cwd: "/tmp/banyan",
            transcriptURL: URL(fileURLWithPath: "/tmp/new.jsonl"),
            createdAt: base.addingTimeInterval(30),
            updatedAt: base.addingTimeInterval(660)
        )
    ]

    let matches = SessionStore.bestPromptTitleAssignments(
        for: sessions,
        in: imported
    )

    #expect(matches["session-a"]?.id == "history-codex-new")
}
