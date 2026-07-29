import Foundation
import BanyanCore
import Testing
@testable import Banyan

@Test func restoreKeepsClosedSessionsHiddenEvenWhenBackingTmuxSessionExists() {
    #expect(SessionStore.restoredStatus(snapshotStatus: .closed) == .closed)
}

@Test func missingBackingTmuxSessionRequiresRecoveryForActiveSnapshot() {
    #expect(SessionStore.shouldMarkForRecovery(
        status: .running,
        tmuxSessionName: "banyan-1",
        liveTmuxSessionNames: []
    ))
    #expect(!SessionStore.shouldMarkForRecovery(
        status: .running,
        tmuxSessionName: "banyan-1",
        liveTmuxSessionNames: ["banyan-1"]
    ))
}

@Test func terminalSnapshotsDoNotRequireRecovery() {
    for status in [SessionStatus.closed, .completed, .failed] {
        #expect(!SessionStore.shouldMarkForRecovery(
            status: status,
            tmuxSessionName: "banyan-1",
            liveTmuxSessionNames: []
        ))
    }
}

@Test func restorePreservesActiveSessionStatus() {
    #expect(SessionStore.restoredStatus(snapshotStatus: .running) == .running)
    #expect(SessionStore.restoredStatus(snapshotStatus: .needInput) == .needInput)
}

@Test func supervisorInspectsRestoredSessionsBeforeTheirTerminalClientAttaches() {
    // Restored-but-unclicked: the row's provider icon and status come from here.
    #expect(SessionStore.participatesInSupervisorTick(isProcessStarted: false, isRestored: true))
    #expect(SessionStore.participatesInSupervisorTick(isProcessStarted: true, isRestored: false))
    // Never launched, or the client terminated: nothing to inspect.
    #expect(!SessionStore.participatesInSupervisorTick(isProcessStarted: false, isRestored: false))
}

@Test func closeConfirmationOnlyTreatsActiveCodexOrClaudeAsOngoingAgents() {
    #expect(SessionStore.isOngoingCodexOrClaudeSession(status: .executing, provider: .codex))
    #expect(SessionStore.isOngoingCodexOrClaudeSession(status: .needInput, provider: .claude))
    #expect(!SessionStore.isOngoingCodexOrClaudeSession(status: .completed, provider: .codex))
    #expect(!SessionStore.isOngoingCodexOrClaudeSession(status: .failed, provider: .claude))
    #expect(!SessionStore.isOngoingCodexOrClaudeSession(status: .executing, provider: .gemini))
    #expect(!SessionStore.isOngoingCodexOrClaudeSession(status: .running, provider: nil))
}

@Test func reopenResumesClosedCodexSessionInsteadOfReplayingLaunchCommand() {
    let codex = SessionStore.reopenResumeCommand(
        status: .closed,
        provider: .codex,
        agentSessionID: "abc12345-0000-0000-0000-000000000000",
        cwd: "/tmp/project"
    )
    #expect(codex == "'codex' 'resume' '-C' '/tmp/project' 'abc12345-0000-0000-0000-000000000000'")

    let claude = SessionStore.reopenResumeCommand(
        status: .closed,
        provider: .claude,
        agentSessionID: "session-uuid",
        cwd: "/tmp/project"
    )
    #expect(claude == "'claude' '--resume' 'session-uuid'")
}

@Test func reopenKeepsOriginalCommandWhenResumeIsNotApplicable() {
    // Still active — nothing to rebuild.
    #expect(SessionStore.reopenResumeCommand(
        status: .running,
        provider: .codex,
        agentSessionID: "abc",
        cwd: "/tmp"
    ) == nil)

    // No underlying agent session resolved.
    #expect(SessionStore.reopenResumeCommand(
        status: .closed,
        provider: .codex,
        agentSessionID: nil,
        cwd: "/tmp"
    ) == nil)

    // Empty agent session id is treated as unresolved.
    #expect(SessionStore.reopenResumeCommand(
        status: .closed,
        provider: .claude,
        agentSessionID: "",
        cwd: "/tmp"
    ) == nil)

    // Provider without resume support.
    #expect(SessionStore.reopenResumeCommand(
        status: .closed,
        provider: .gemini,
        agentSessionID: "abc",
        cwd: "/tmp"
    ) == nil)

    // Plain shell session (no agent provider).
    #expect(SessionStore.reopenResumeCommand(
        status: .closed,
        provider: nil,
        agentSessionID: "abc",
        cwd: "/tmp"
    ) == nil)
}

@Test func closedAgentWithoutSessionIDRequiresRecoveryBeforeRespawn() {
    #expect(SessionStore.requiresDeepHistoryRecovery(
        status: .closed,
        provider: .codex,
        agentSessionID: nil
    ))
    #expect(SessionStore.requiresDeepHistoryRecovery(
        status: .closed,
        provider: .claude,
        agentSessionID: ""
    ))
    #expect(!SessionStore.requiresDeepHistoryRecovery(
        status: .closed,
        provider: .codex,
        agentSessionID: "session-id"
    ))
    #expect(!SessionStore.requiresDeepHistoryRecovery(
        status: .running,
        provider: .codex,
        agentSessionID: nil
    ))
    #expect(!SessionStore.requiresDeepHistoryRecovery(
        status: .closed,
        provider: .gemini,
        agentSessionID: nil
    ))
}

@Test func missingHistoryResumeDoesNotPromiseAFreshRestart() {
    let message = SessionStore.missingHistoryResumeMessage(provider: .claude)
    #expect(message.contains("No resumable Claude session"))
    #expect(message.contains("original command was not restarted"))
}

@Test func missingHistoryResumeFallbackLaunchesZsh() {
    #expect(SessionStore.historyFallbackShellCommand == "/bin/zsh -l")
}

@Test func backgroundHistoryImportCoversEveryBoundedSearchResult() {
    #expect(SessionStore.historyRecoveryImportLimit >= SessionStore.historySidebarSearchLimit)
}

@Test func liveAgentMatchIncludesPinnedTitleSessionsSoAgentSessionIDResolves() {
    // Regression: pinned-title sessions (Linear worktrees launched with an
    // explicit "ENG-1234 …" title) must still take part in the transcript match
    // so their agentSessionID is captured — otherwise reopening a closed one
    // replays the initial prompt instead of resuming. Pinning is not one of the
    // predicate's inputs, so a pinned codex/claude session participates.
    #expect(SessionStore.participatesInLiveAgentMatch(
        isImportedHistory: false, status: .running, provider: .claude
    ))
    #expect(SessionStore.participatesInLiveAgentMatch(
        isImportedHistory: false, status: .needInput, provider: .codex
    ))
    // Unknown provider is still allowed (it gets detected during the pass).
    #expect(SessionStore.participatesInLiveAgentMatch(
        isImportedHistory: false, status: .running, provider: nil
    ))
}

@Test func liveAgentMatchExcludesClosedImportedAndNonAgentSessions() {
    #expect(!SessionStore.participatesInLiveAgentMatch(
        isImportedHistory: false, status: .closed, provider: .claude
    ))
    #expect(!SessionStore.participatesInLiveAgentMatch(
        isImportedHistory: true, status: .running, provider: .codex
    ))
    #expect(!SessionStore.participatesInLiveAgentMatch(
        isImportedHistory: false, status: .running, provider: .gemini
    ))
}

@Test func startupCleanupOnlyTargetsUnpersistedBanyanTmuxSessions() {
    let stale = SessionStore.staleTmuxSessionNames(
        liveSessionNames: ["banyan-session-2", "banyan-session-1", "banyan-session-3"],
        persistedSessionNames: ["banyan-session-1", "banyan-session-3"]
    )

    #expect(stale == ["banyan-session-2"])
}

@Test func historySidebarTitleUsesIssueIDInsteadOfWorktreeName() {
    let title = SessionStore.historySidebarTitle(
        projectName: "yudu-eng-6061-32baaf",
        displayTitle: "Personal coding run",
        issueID: "ENG-6061"
    )

    #expect(title == "ENG-6061 · Personal coding run")
}

@Test func historyFilterMatchesTokensAgainstTheRenderedRowTitle() {
    let title = SessionStore.historySidebarTitle(
        projectName: "clawly",
        displayTitle: "Fix stale provider icon",
        issueID: "ENG-6061"
    )

    #expect(SessionStore.matchesHistoryFilter(title: title, query: ""))
    #expect(SessionStore.matchesHistoryFilter(title: title, query: "   "))
    #expect(SessionStore.matchesHistoryFilter(title: title, query: "eng-6061"))
    #expect(SessionStore.matchesHistoryFilter(title: title, query: "PROVIDER"))
    // Tokens may match out of order, and all of them must match.
    #expect(SessionStore.matchesHistoryFilter(title: title, query: "icon eng-6061"))
    #expect(!SessionStore.matchesHistoryFilter(title: title, query: "icon eng-9999"))
    #expect(!SessionStore.matchesHistoryFilter(title: title, query: "codex"))
}

@Test func historySidebarShowsMoreRowsWhenSearchingThanWhenBrowsing() {
    #expect(SessionStore.historySidebarBrowseLimit == 30)
    #expect(SessionStore.historySidebarSearchLimit > SessionStore.historySidebarBrowseLimit)
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

@Test func sidebarMoveReordersOnlyTheMovedProjectGroup() {
    let reordered = SessionStore.reorderedSidebarSessionIDs(
        activeSidebarIDs: ["one", "two", "three", "four", "five"],
        groupSessionIDs: ["two", "three", "four"],
        sourceOffsets: IndexSet(integer: 0),
        destinationOffset: 3
    )

    #expect(reordered == ["one", "three", "four", "two", "five"])
}

@Test func sidebarMovePreservesRowsOutsideTheMovedProjectGroup() {
    let reordered = SessionStore.reorderedSidebarSessionIDs(
        activeSidebarIDs: ["project-a-1", "project-a-2", "project-b-1", "project-b-2"],
        groupSessionIDs: ["project-b-1", "project-b-2"],
        sourceOffsets: IndexSet(integer: 1),
        destinationOffset: 0
    )

    #expect(reordered == ["project-a-1", "project-a-2", "project-b-2", "project-b-1"])
}

@Test func sidebarDragDropAfterTargetWhenDraggingDown() {
    let reordered = SessionStore.reorderedSidebarSessionIDs(
        activeSidebarIDs: ["one", "two", "three", "four"],
        groupSessionIDs: ["one", "two", "three", "four"],
        sourceID: "one",
        targetID: "three"
    )

    #expect(reordered == ["two", "three", "one", "four"])
}

@Test func sidebarDragDropBeforeTargetWhenDraggingUp() {
    let reordered = SessionStore.reorderedSidebarSessionIDs(
        activeSidebarIDs: ["one", "two", "three", "four"],
        groupSessionIDs: ["one", "two", "three", "four"],
        sourceID: "four",
        targetID: "two"
    )

    #expect(reordered == ["one", "four", "two", "three"])
}

@MainActor
@Test func localHistoryIncludesClosedCodexSessionsWithLinearIssueIDs() {
    let base = Date(timeIntervalSince1970: 1_787_500_000)
    let session = BanyanSession(
        id: "banyan-session",
        title: "ENG-123 Closed in Banyan",
        cwd: "/tmp/banyan",
        command: "codex",
        status: .closed,
        tone: .neutral,
        createdAt: base,
        updatedAt: base,
        isRestored: true,
        theme: .system,
        tmuxBackend: TmuxBackend.shared,
        telemetry: PerformanceTelemetry.shared,
        host: banyanTestHost
    )

    #expect(SessionStore.isLocalHistorySession(session))
}

@MainActor
@Test func localHistoryIncludesClosedClaudeSessionsWithLinearIssueIDs() {
    let base = Date(timeIntervalSince1970: 1_787_500_000)
    let session = BanyanSession(
        id: "banyan-session",
        title: "ENG-456 Closed Claude session",
        cwd: "/tmp/banyan",
        command: "claude",
        status: .closed,
        tone: .neutral,
        createdAt: base,
        updatedAt: base,
        isRestored: true,
        theme: .system,
        tmuxBackend: TmuxBackend.shared,
        telemetry: PerformanceTelemetry.shared,
        host: banyanTestHost
    )

    #expect(SessionStore.isLocalHistorySession(session))
}

@MainActor
@Test func localHistoryExcludesExternalImportedSessions() {
    let base = Date(timeIntervalSince1970: 1_787_500_000)
    let session = BanyanSession(
        id: "history-codex-external",
        title: "External handoff session",
        cwd: "/tmp/banyan",
        command: "codex",
        status: .completed,
        tone: .neutral,
        historyTranscriptURL: URL(fileURLWithPath: "/tmp/external.jsonl"),
        createdAt: base,
        updatedAt: base,
        isRestored: true,
        theme: .system,
        tmuxBackend: TmuxBackend.shared,
        telemetry: PerformanceTelemetry.shared,
        host: banyanTestHost
    )

    #expect(!SessionStore.isLocalHistorySession(session))
}

@MainActor
@Test func localHistoryExcludesClosedSessionsWithoutLinearIssueIDs() {
    let base = Date(timeIntervalSince1970: 1_787_500_000)
    let session = BanyanSession(
        id: "closed-session",
        title: "Closed without issue id",
        cwd: "/tmp/banyan",
        command: "codex",
        status: .closed,
        tone: .neutral,
        createdAt: base,
        updatedAt: base,
        isRestored: true,
        theme: .system,
        tmuxBackend: TmuxBackend.shared,
        telemetry: PerformanceTelemetry.shared,
        host: banyanTestHost
    )

    #expect(!SessionStore.isLocalHistorySession(session))
}

@MainActor
@Test func localHistoryExcludesClosedNonCodexClaudeSessions() {
    let base = Date(timeIntervalSince1970: 1_787_500_000)
    let session = BanyanSession(
        id: "closed-session",
        title: "ENG-789 Closed shell session",
        cwd: "/tmp/banyan",
        command: "zsh",
        status: .closed,
        tone: .neutral,
        createdAt: base,
        updatedAt: base,
        isRestored: true,
        theme: .system,
        tmuxBackend: TmuxBackend.shared,
        telemetry: PerformanceTelemetry.shared,
        host: banyanTestHost
    )

    #expect(!SessionStore.isLocalHistorySession(session))
}

@MainActor
@Test func localHistoryExcludesActiveBanyanSessions() {
    let base = Date(timeIntervalSince1970: 1_787_500_000)
    let session = BanyanSession(
        id: "active-session",
        title: "Still active",
        cwd: "/tmp/banyan",
        command: "codex",
        status: .running,
        tone: .blue,
        createdAt: base,
        updatedAt: base,
        isRestored: true,
        theme: .system,
        tmuxBackend: TmuxBackend.shared,
        telemetry: PerformanceTelemetry.shared,
        host: banyanTestHost
    )

    #expect(!SessionStore.isLocalHistorySession(session))
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

@Test func historyResumeFallsBackToExactWorkingDirectoryBeyondCreationWindow() {
    let base = Date(timeIntervalSince1970: 1_787_500_000)
    let resumedTranscript = ImportedAgentSession(
        id: "history-codex-worktree",
        provider: .codex,
        sourceID: "worktree",
        title: "Earlier session in the same worktree",
        cwd: "/tmp/.worktrees/eng-1234",
        transcriptURL: URL(fileURLWithPath: "/tmp/worktree.jsonl"),
        createdAt: base.addingTimeInterval(-86_400),
        updatedAt: base.addingTimeInterval(3_590)
    )
    let otherWorktree = ImportedAgentSession(
        id: "history-codex-other",
        provider: .codex,
        sourceID: "other",
        title: "Another issue",
        cwd: "/tmp/.worktrees/eng-9999",
        transcriptURL: URL(fileURLWithPath: "/tmp/other.jsonl"),
        createdAt: base,
        updatedAt: base.addingTimeInterval(3_600)
    )

    let match = SessionStore.bestHistoryResumeMatch(
        sessionCWD: "/tmp/.worktrees/eng-1234/../eng-1234",
        sessionCreatedAt: base,
        sessionUpdatedAt: base.addingTimeInterval(3_600),
        sessionResetAt: nil,
        provider: .codex,
        in: [otherWorktree, resumedTranscript]
    )

    #expect(match?.id == "history-codex-worktree")
}

@Test func historyResumeUsesActivityNearestSessionCloseForSharedDirectory() {
    let base = Date(timeIntervalSince1970: 1_787_500_000)
    let older = ImportedAgentSession(
        id: "history-claude-older",
        provider: .claude,
        sourceID: "older",
        title: "Older session",
        cwd: "/tmp/shared",
        transcriptURL: URL(fileURLWithPath: "/tmp/older.jsonl"),
        createdAt: base.addingTimeInterval(-20_000),
        updatedAt: base.addingTimeInterval(1_000)
    )
    let current = ImportedAgentSession(
        id: "history-claude-current",
        provider: .claude,
        sourceID: "current",
        title: "Current session",
        cwd: "/tmp/shared",
        transcriptURL: URL(fileURLWithPath: "/tmp/current.jsonl"),
        createdAt: base.addingTimeInterval(-10_000),
        updatedAt: base.addingTimeInterval(3_590)
    )

    let match = SessionStore.bestHistoryResumeMatch(
        sessionCWD: "/tmp/shared",
        sessionCreatedAt: base,
        sessionUpdatedAt: base.addingTimeInterval(3_600),
        sessionResetAt: nil,
        provider: .claude,
        in: [older, current]
    )

    #expect(match?.id == "history-claude-current")
}

@Test func promptTitleAssignmentsDoNotReuseOneHistoryTitleForMultipleSessions() {
    let base = Date(timeIntervalSince1970: 1_787_500_000)
    let sessions = [
        AgentSessionMatchInput(
            id: "session-a",
            cwd: "/tmp/banyan",
            createdAt: base,
            resetAt: nil,
            provider: .codex
        ),
        AgentSessionMatchInput(
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
        AgentSessionMatchInput(
            id: "session-a",
            cwd: "/tmp/banyan",
            createdAt: base,
            resetAt: nil,
            provider: .codex
        ),
        AgentSessionMatchInput(
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
        AgentSessionMatchInput(
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
