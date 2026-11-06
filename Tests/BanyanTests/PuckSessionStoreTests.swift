import BanyanCore
import Foundation
import Testing
@testable import Banyan

/// A puck session is a session like any other: it sits in the same list, with
/// the same status, close, and "new session like this one" behavior. Only the
/// runtime behind it differs, and these tests pin where it does.

@MainActor
@Test func openingAListedPuckSessionAddsItToTheSessionList() throws {
    let daemon = FakePuckDaemon()
    let fixture = try PuckStoreFixture(daemon: daemon)
    let store = fixture.makeStore()
    store.sidebarScope = .all
    store.loadPersistedSessionsIfNeeded()
    daemon.put(puckSummary(model: "gpt-5.5", cwd: fixture.project.path, position: "running"))

    store.applyPuckSummaries(try daemon.list())
    #expect(store.sessions.isEmpty)
    store.openPuckSession(id: try #require(store.backgroundPuckSummaries.first?.id))

    let session = try #require(store.sessions.first as? PuckSession)
    #expect(session.backendKind == .puck)
    #expect(session.status == .executing)
    #expect(session.displayAgentProvider == .codex)
    #expect(session.detectedAgentModelID == "gpt-5.5")
    #expect(session.cwd == fixture.project.path)
    // The daemon ID is a UUID; it must not become the row's title.
    #expect(!session.displayTitle.contains(session.id))
    // Jump keys and the attention chord walk the sidebar rows.
    #expect(store.unifiedSidebarGroups.flatMap(\.items).map(\.id).contains(session.id))
    #expect(store.selectedSessionID == session.id)
    #expect(store.backgroundPuckSummaries.isEmpty)
}

@MainActor
@Test func daemonListingDrivesPuckSessionStatus() throws {
    let daemon = FakePuckDaemon()
    let fixture = try PuckStoreFixture(daemon: daemon)
    let store = fixture.makeStore()
    let summary = puckSummary(cwd: fixture.project.path, position: "running")
    store.openListedPuckSessions([summary])
    let session = try #require(store.sessions.first)

    // A finished turn leaves a result to read; nobody asked for input.
    store.applyPuckSummaries([summary.with(position: "idle", historyItems: 1)])
    #expect(session.status == .review)
    #expect(!session.status.isAwaitingHumanAnswer)

    let approval = PuckPendingApproval(callID: "call-1", tool: "shell", arguments: "rm -rf build", expiresAtMS: 0)
    store.applyPuckSummaries([summary.with(position: "parked", pendingApproval: .some(approval))])
    #expect(session.status == .asking)

    // Gone from the daemon: nothing is left to follow or reopen.
    store.applyPuckSummaries([])
    #expect(session.status == .closed)
}

@MainActor
@Test func anUnreachableDaemonLeavesPuckRowsAsTheyWere() async throws {
    let daemon = FakePuckDaemon()
    let fixture = try PuckStoreFixture(daemon: daemon)
    let store = fixture.makeStore()
    store.openListedPuckSessions([puckSummary(cwd: fixture.project.path, position: "running")])
    let session = try #require(store.sessions.first)

    daemon.isReachable = false
    store.syncPuckSessions()
    try await Task.sleep(for: .milliseconds(200))

    #expect(session.status == .executing)
}

@MainActor
@Test func closingAPuckSessionConfirmsFirstAndLeavesTheDaemonSessionAlone() throws {
    let daemon = FakePuckDaemon()
    let fixture = try PuckStoreFixture(daemon: daemon)
    let store = fixture.makeStore()
    let summary = puckSummary(cwd: fixture.project.path, position: "running", historyItems: 1)
    daemon.put(summary)
    store.openListedPuckSessions([summary])
    let session = try #require(store.sessions.first)

    // Closing a puck session only stops Banyan from showing it, but every close
    // asks first so the tradeoff is never a surprise.
    store.requestClose(id: session.id)
    #expect(store.pendingCloseSession?.id == session.id)
    #expect(session.status == .executing)

    store.cancelPendingClose()
    #expect(store.pendingCloseSession == nil)
    #expect(session.status == .executing)

    store.requestClose(id: session.id)
    store.confirmPendingClose()
    #expect(session.status == .closed)
    #expect(try daemon.list().map(\.id) == [session.id])

    // The daemon still lists it, which must not reopen it.
    store.applyPuckSummaries([summary])
    #expect(session.status == .closed)

    try store.respawn(id: session.id)
    #expect(session.status == .executing)
    #expect(store.selectedSessionID == session.id)
}

@MainActor
@Test func removedPuckSessionsStayRemovedAndCanBeOpenedAgain() throws {
    let daemon = FakePuckDaemon()
    let fixture = try PuckStoreFixture(daemon: daemon)
    let summary = puckSummary(cwd: fixture.project.path)
    daemon.put(summary)
    let store = fixture.makeStore()
    store.loadPersistedSessionsIfNeeded()
    store.openListedPuckSessions(try daemon.list())

    try store.remove(id: summary.id)
    store.applyPuckSummaries(try daemon.list())
    #expect(store.sessions.isEmpty)
    #expect(store.backgroundPuckSummaries.map(\.id) == [summary.id])

    // Across a relaunch too, and after the daemon forgets and relists it.
    store.flushPendingSessionSaves()
    let relaunched = fixture.makeStore()
    relaunched.loadPersistedSessionsIfNeeded()
    relaunched.applyPuckSummaries(try daemon.list())
    #expect(relaunched.sessions.isEmpty)
    daemon.forget(summary.id)
    relaunched.applyPuckSummaries(try daemon.list())
    daemon.put(summary)
    relaunched.applyPuckSummaries(try daemon.list())
    #expect(relaunched.sessions.isEmpty)

    // Removing was presentation only: the daemon still has it to reopen.
    relaunched.openPuckSession(id: summary.id)
    #expect(relaunched.sessions.map(\.id) == [summary.id])
    #expect(relaunched.selectedSessionID == summary.id)
}

@MainActor
@Test func aListingDuringACreateDoesNotAddTheSessionTwice() async throws {
    let daemon = FakePuckDaemon()
    let fixture = try PuckStoreFixture(daemon: daemon)
    let store = fixture.makeStore()
    let gate = daemon.holdCreates()
    let creation = Task { @MainActor in
        try await store.createPuckSession(binding: PuckSessionBinding(provider: "codex"), cwd: fixture.project.path)
    }
    // The daemon has the session, and lists it, before its create returns.
    try await waitForPuckState { daemon.creations.count == 1 }
    store.applyPuckSummaries(try daemon.list())
    #expect(store.sessions.isEmpty)

    gate.signal()
    let created = try await creation.value
    #expect(store.sessions.map(\.id) == [created.id])
}

@MainActor
@Test func aListingRequestedBeforeACreateDoesNotCloseTheNewSession() async throws {
    let daemon = FakePuckDaemon()
    let fixture = try PuckStoreFixture(daemon: daemon)
    let store = fixture.makeStore()
    let gate = daemon.holdLists()
    store.syncPuckSessions()

    let created = try await store.createPuckSession(
        binding: PuckSessionBinding(provider: "codex"),
        cwd: fixture.project.path
    )
    // The listing read the daemon before the session existed.
    gate.signal()
    try await waitForPuckState { daemon.listsReturned == 1 }
    try await Task.sleep(for: .milliseconds(100))

    #expect(created.status != .closed)
    #expect(store.sessions.map(\.id) == [created.id])
}

@MainActor
@Test func newSessionFromAPuckSessionStartsOneOnTheSameRuntime() async throws {
    let daemon = FakePuckDaemon()
    let fixture = try PuckStoreFixture(daemon: daemon)
    let store = fixture.makeStore()
    let summary = puckSummary(provider: "opencode-go", account: "work", model: "glm-4.6", cwd: fixture.project.path)
    daemon.put(summary)
    store.openListedPuckSessions([summary])
    store.userSelect(id: summary.id)

    // What Cmd-N runs.
    store.spawnSiblingSession()
    try await waitForPuckState { store.sessions.count == 2 }

    #expect(daemon.creations.map(\.provider) == ["opencode-go"])
    #expect(daemon.creations.map(\.account) == ["work"])
    #expect(daemon.creations.map(\.model) == ["glm-4.6"])
    #expect(daemon.creations.map(\.workspace) == [fixture.project.path])
    let sibling = try #require(store.sessions.last as? PuckSession)
    #expect(sibling.binding == PuckSessionBinding(provider: "opencode-go", account: "work", model: "glm-4.6"))
    #expect(sibling.displayAgentProvider == .zai)
    #expect(store.selectedSessionID == sibling.id)
}

@MainActor
@Test func puckSessionsMatchOnlyPuckLaunchProfiles() throws {
    let daemon = FakePuckDaemon()
    let fixture = try PuckStoreFixture(daemon: daemon)
    let store = fixture.makeStore()
    store.openListedPuckSessions([puckSummary(cwd: fixture.project.path)])
    let puck = try #require(store.sessions.first)
    let terminal = TerminalSession(
        id: "terminal-codex",
        title: "Codex",
        cwd: fixture.project.path,
        command: "codex",
        isRestored: true,
        theme: .system,
        tmuxBackend: banyanTestTmuxBackend,
        telemetry: banyanTestTelemetry,
        host: banyanTestHost
    )

    // Both run Codex; the row's brand still follows how each was launched.
    #expect(store.sessionLaunchProfile(for: puck)?.id == "codex-puck")
    #expect(store.sessionLaunchProfile(for: terminal)?.id == "codex")
}

@MainActor
@Test func creatingAPuckSessionWithAPromptStartsItsFirstTurnAndNamesIt() async throws {
    let daemon = FakePuckDaemon()
    let fixture = try PuckStoreFixture(daemon: daemon)
    let store = fixture.makeStore()

    let session = try await store.createPuckSession(
        binding: PuckSessionBinding(provider: "codex"),
        cwd: fixture.project.path,
        prompt: "fix the flaky parser test"
    )

    #expect(daemon.turns == [FakePuckDaemon.Turn(id: session.id, prompt: "fix the flaky parser test")])
    #expect(session.status == .executing)
    #expect(session.displayTitle == "fix the flaky parser test")
    #expect(store.selectedSessionID == session.id)
}

@MainActor
@Test func puckSessionsComeBackAfterARelaunch() async throws {
    let daemon = FakePuckDaemon()
    let fixture = try PuckStoreFixture(daemon: daemon)
    let store = fixture.makeStore()
    store.loadPersistedSessionsIfNeeded()
    let created = try await store.createPuckSession(
        binding: PuckSessionBinding(provider: "anthropic", account: "key", model: "claude-sonnet-4-5"),
        cwd: fixture.project.path,
        title: "Parser fixes"
    )
    store.flushPendingSessionSaves()

    let relaunched = fixture.makeStore()
    relaunched.loadPersistedSessionsIfNeeded()

    let restored = try #require(relaunched.sessions.first as? PuckSession)
    #expect(restored.id == created.id)
    #expect(restored.binding == created.binding)
    #expect(restored.displayTitle == "Parser fixes")
    #expect(restored.displayAgentProvider == .claude)
}

@MainActor
@Test func puckSessionsRefusePaneReadsAndInput() throws {
    let daemon = FakePuckDaemon()
    let fixture = try PuckStoreFixture(daemon: daemon)
    let store = fixture.makeStore()
    store.openListedPuckSessions([puckSummary(cwd: fixture.project.path)])
    let session = try #require(store.sessions.first)

    do {
        _ = try store.paneTarget(id: session.id)
        Issue.record("a puck session has no terminal pane")
    } catch let error as ControlError {
        #expect(error.code == "session_has_no_pane")
    }
}

@MainActor
@Test func followingAPuckSessionMirrorsItsTranscript() async throws {
    let daemon = FakePuckDaemon()
    let fixture = try PuckStoreFixture(daemon: daemon)
    let store = fixture.makeStore()
    let summary = puckSummary(cwd: fixture.project.path, position: "running")
    daemon.put(summary, transcript: [PuckSessionEvent(cursor: 1, kind: "turn_started")])
    store.openListedPuckSessions([summary])
    let session = try #require(store.sessions.first as? PuckSession)

    session.startFollowing()
    try await waitForPuckState { session.followState == .following }
    #expect(session.events.map(\.cursor) == [1])

    // Replay and live delivery can overlap; the cursor keeps one copy.
    daemon.push(.events([
        PuckSessionEvent(cursor: 1, kind: "turn_started"),
        PuckSessionEvent(cursor: 2, kind: "turn_done", text: "done")
    ]), to: session.id)
    daemon.push(.summary(summary.with(position: "idle", historyItems: 1)), to: session.id)
    try await waitForPuckState { session.status == .review }
    #expect(session.events.map(\.cursor) == [1, 2])

    // A dropped stream shows as lost, and following again reattaches.
    daemon.dropFollower(session.id)
    try await waitForPuckState { session.followState == .lost }
    session.startFollowing()
    try await waitForPuckState { session.followState == .following }

    session.stopFollowing()
    #expect(session.followState == .stopped)
    #expect(session.events.map(\.cursor) == [1])
    try await waitForPuckState { !daemon.isFollowed(session.id) }
}

@MainActor
@Test func switchingBackKeepsCachedTranscriptUntilReplayCompletes() async throws {
    let daemon = FakePuckDaemon()
    let fixture = try PuckStoreFixture(daemon: daemon)
    let store = fixture.makeStore()
    let summary = puckSummary(cwd: fixture.project.path, position: "idle")
    daemon.put(summary, transcript: [
        PuckSessionEvent(cursor: 1, kind: "user_message", text: "Hello"),
        PuckSessionEvent(cursor: 2, kind: "assistant_message", text: "Hi there"),
    ])
    store.openListedPuckSessions([summary])
    let session = try #require(store.sessions.first as? PuckSession)

    session.startFollowing()
    try await waitForPuckState { session.followState == .following }
    #expect(session.events.map(\.cursor) == [1, 2])

    session.stopFollowing()
    #expect(session.events.map(\.cursor) == [1, 2])

    session.startFollowing()
    #expect(session.followState == .connecting)
    #expect(session.events.map(\.cursor) == [1, 2])
    try await waitForPuckState { session.followState == .following }
    #expect(session.events.map(\.cursor) == [1, 2])
    session.stopFollowing()
}

@MainActor
@Test func submittedPromptAppearsImmediatelyAndReconcilesWithTheDaemonEcho() async throws {
    let daemon = FakePuckDaemon()
    let fixture = try PuckStoreFixture(daemon: daemon)
    let store = fixture.makeStore()
    let summary = puckSummary(cwd: fixture.project.path, position: "idle")
    daemon.put(summary)
    store.openListedPuckSessions([summary])
    let session = try #require(store.sessions.first as? PuckSession)

    session.startFollowing()
    try await waitForPuckState { session.followState == .following }
    let gate = daemon.holdTurns()
    session.draft = "Inspect the parser"
    session.send(session.draft)

    // The row and composer update synchronously; the daemon has not acknowledged yet.
    #expect(session.draft.isEmpty)
    #expect(daemon.turns.isEmpty)
    #expect(session.timeline.items.filter { $0.role == .user }.map(\.text) == ["Inspect the parser"])

    gate.signal()
    try await waitForPuckState { daemon.turns.count == 1 && !session.admissionTurnInFlight }
    #expect(session.timeline.items.filter { $0.role == .user }.map(\.text) == ["Inspect the parser"])

    daemon.push(.events([
        PuckSessionEvent(cursor: 2, kind: "user_message", text: "Inspect the parser"),
    ]), to: session.id)
    try await waitForPuckState { session.events.contains { $0.kind == "user_message" } }
    #expect(session.timeline.items.filter { $0.role == .user }.map(\.text) == ["Inspect the parser"])

    daemon.push(.history(PuckHistoryPage(
        session: session.id,
        source: "display",
        items: [
            PuckHistoryItem(id: "user-1", turnID: "turn-1", kind: "user", text: "Inspect the parser"),
            PuckHistoryItem(id: "assistant-1", turnID: "turn-1", kind: "assistant", text: "Done"),
        ],
        nextCursor: nil
    )), to: session.id)
    try await waitForPuckState { session.historyItems.count == 2 }
    #expect(session.timeline.items.filter { $0.role == .user }.map(\.text) == ["Inspect the parser"])
    session.stopFollowing()
}

@MainActor
@Test func repeatedPromptDoesNotHideAllCopiesWhenTheDaemonEchoArrives() async throws {
    let daemon = FakePuckDaemon()
    let fixture = try PuckStoreFixture(daemon: daemon)
    let store = fixture.makeStore()
    let summary = puckSummary(cwd: fixture.project.path, position: "idle")
    daemon.put(summary, transcript: [
        PuckSessionEvent(cursor: 1, kind: "user_message", text: "Try again"),
    ])
    store.openListedPuckSessions([summary])
    let session = try #require(store.sessions.first as? PuckSession)

    session.startFollowing()
    try await waitForPuckState { session.events.count == 1 }
    let gate = daemon.holdTurns()
    session.send("Try again")
    #expect(session.timeline.items.filter { $0.role == .user }.map(\.text) == ["Try again", "Try again"])

    gate.signal()
    try await waitForPuckState { daemon.turns.count == 1 && !session.admissionTurnInFlight }
    daemon.push(.events([
        PuckSessionEvent(cursor: 2, kind: "user_message", text: "Try again"),
    ]), to: session.id)
    try await waitForPuckState { session.events.count == 2 }

    // The canonical echo replaces only the optimistic copy, not the older prompt.
    #expect(session.timeline.items.filter { $0.role == .user }.map(\.text) == ["Try again", "Try again"])
    session.stopFollowing()
}

@MainActor
@Test func rejectedPromptWithdrawsTheOptimisticRowAndRestoresTheDraft() async throws {
    let daemon = FakePuckDaemon()
    let fixture = try PuckStoreFixture(daemon: daemon)
    let store = fixture.makeStore()
    let summary = puckSummary(cwd: fixture.project.path, position: "idle")
    daemon.put(summary)
    daemon.turnError = .rejected("busy")
    store.openListedPuckSessions([summary])
    let session = try #require(store.sessions.first as? PuckSession)

    session.draft = "Do not lose this"
    session.send(session.draft)
    #expect(session.timeline.items.contains { $0.role == .user && $0.text == "Do not lose this" })

    try await waitForPuckState(timeout: .seconds(15)) { daemon.turnAttempts == 1 && session.daemonError != nil }
    #expect(session.draft == "Do not lose this")
    #expect(!session.timeline.items.contains { $0.role == .user && $0.text == "Do not lose this" })
}

@MainActor
@Test func uncertainPromptDeliveryKeepsTheOptimisticRow() async throws {
    let daemon = FakePuckDaemon()
    let fixture = try PuckStoreFixture(daemon: daemon)
    let store = fixture.makeStore()
    let summary = puckSummary(cwd: fixture.project.path, position: "idle")
    daemon.put(summary)
    daemon.turnError = .unavailable("Socket closed before an acknowledgement")
    store.openListedPuckSessions([summary])
    let session = try #require(store.sessions.first as? PuckSession)

    session.draft = "Maybe delivered"
    session.send(session.draft)
    try await waitForPuckState(timeout: .seconds(15)) { daemon.turnAttempts == 1 && session.daemonError != nil }

    // The daemon may have accepted the turn before the connection dropped, so
    // keeping the row is safer than showing a message that was never sent.
    #expect(session.draft.isEmpty)
    #expect(session.timeline.items.filter { $0.role == .user }.map(\.text) == ["Maybe delivered"])
}

@MainActor
@Test func puckSessionsSayWhyTheyCannotTakeATurn() throws {
    let daemon = FakePuckDaemon()
    let fixture = try PuckStoreFixture(daemon: daemon)
    let store = fixture.makeStore()
    let summary = puckSummary(cwd: fixture.project.path)
    store.openListedPuckSessions([summary])
    let session = try #require(store.sessions.first as? PuckSession)
    #expect(session.turnUnavailableReason == nil)

    store.applyPuckSummaries([summary.with(position: "running")])
    #expect(session.turnUnavailableReason != nil)

    let approval = PuckPendingApproval(callID: "call-1", tool: "shell", arguments: "ls", expiresAtMS: 0)
    store.applyPuckSummaries([summary.with(position: "parked", pendingApproval: .some(approval))])
    #expect(session.turnUnavailableReason != nil)
}

@MainActor
@Test func puckTurnPhaseDistinguishesWaitingForAnAsk() throws {
    let daemon = FakePuckDaemon()
    let fixture = try PuckStoreFixture(daemon: daemon)
    let store = fixture.makeStore()
    let summary = puckSummary(cwd: fixture.project.path, position: "running")
    store.openListedPuckSessions([summary])
    let session = try #require(store.sessions.first as? PuckSession)

    #expect(session.turnPhase == .running)
    #expect(session.canCancelTurn)
    #expect(session.turnUnavailableReason != nil)

    let approval = PuckPendingApproval(callID: "call-1", tool: "shell", arguments: "ls", expiresAtMS: 0)
    store.applyPuckSummaries([summary.with(position: "parked", pendingApproval: .some(approval))])
    #expect(session.turnPhase == .waitingForApproval)
    #expect(session.status == .asking)
    #expect(session.canCancelTurn)

    let question = try PuckPendingQuestion([
        "call_id": "ask-1", "expires_at_ms": 0,
        "questions": [[
            "header": "Files", "question": "Which files?", "multiple": false,
            "custom": false,
            "options": [["label": "One", "description": "Use one file."]],
        ]],
    ])
    store.applyPuckSummaries([summary.with(position: "parked", pendingQuestion: .some(question))])
    #expect(session.turnPhase == .waitingForAnswer)
    #expect(session.status == .asking)

    store.applyPuckSummaries([summary.with(position: "parked", historyItems: 1)])
    #expect(session.turnPhase == .parked)
    store.applyPuckSummaries([summary.with(position: "idle", historyItems: 1)])
    #expect(session.turnPhase == .idle)
    #expect(!session.canCancelTurn)
    #expect(session.turnUnavailableReason == nil)
    store.applyPuckSummaries([summary.with(position: "interrupted", historyItems: 1)])
    #expect(session.turnPhase == .interrupted)
    store.applyPuckSummaries([summary.with(position: "hibernated", historyItems: 1)])
    #expect(session.turnPhase == .hibernated)
}

@MainActor
@Test func cancellingAPuckTurnUsesTheDaemonAndKeepsTheSessionAvailable() async throws {
    let daemon = FakePuckDaemon()
    let fixture = try PuckStoreFixture(daemon: daemon)
    let store = fixture.makeStore()
    let summary = puckSummary(cwd: fixture.project.path, position: "running", historyItems: 1)
    daemon.put(summary, transcript: [
        PuckSessionEvent(cursor: 1, kind: "turn_started"),
        PuckSessionEvent(cursor: 2, kind: "assistant_message", text: "Working", itemID: "assistant-1"),
    ])
    store.openListedPuckSessions([summary])
    let session = try #require(store.sessions.first as? PuckSession)
    session.startFollowing()
    try await waitForPuckState { session.followState == .following }
    daemon.push(.history(PuckHistoryPage(
        session: session.id,
        source: "display",
        items: [PuckHistoryItem(id: "assistant-1", turnID: "turn-1", kind: "assistant", text: "Durable reply")],
        nextCursor: nil
    )), to: session.id)
    try await waitForPuckState { session.historyItems.count == 1 }

    session.cancel()
    try await waitForPuckState { session.position == "interrupted" && !session.cancelInFlight }

    #expect(daemon.cancellations == [session.id])
    #expect(session.status == .failed)
    #expect(session.turnPhase == .interrupted)
    #expect(session.followState == .following)
    #expect(session.historyItems.map(\.id) == ["assistant-1"])
    #expect(session.events.contains { $0.kind == "turn_error" && $0.text == "Turn cancelled by user" })
    #expect(session.timeline.notices.map(\.text) == ["Turn cancelled by user"])
    #expect(session.cancellationNotice == "Turn stopped. This session and its history remain available.")
    #expect(session.turnUnavailableReason == nil)
    #expect(session.status != .closed)
}

@MainActor
@Test func confirmingAPuckApprovalHidesItBeforeTheSummaryReturns() async throws {
    let daemon = FakePuckDaemon()
    let fixture = try PuckStoreFixture(daemon: daemon)
    let store = fixture.makeStore()
    let approval = PuckPendingApproval(callID: "approval-1", tool: "shell", arguments: "ls", expiresAtMS: 0)
    let summary = puckSummary(cwd: fixture.project.path, position: "parked", pendingApproval: approval)
    daemon.put(summary)
    store.openListedPuckSessions([summary])
    let session = try #require(store.sessions.first as? PuckSession)
    let gate = daemon.holdNextGet(after: 0)

    session.decide("approve")
    try await waitForPuckState { daemon.decisions == ["approve"] }

    #expect(session.decisionInFlight)
    #expect(session.pendingApproval == nil)
    store.applyPuckSummaries([summary])
    #expect(session.pendingApproval == nil)
    gate.signal()
    try await waitForPuckState { !session.decisionInFlight }
    #expect(session.position == "running")
}

@MainActor
@Test func confirmingAPuckQuestionHidesItBeforeTheSummaryReturns() async throws {
    let daemon = FakePuckDaemon()
    let fixture = try PuckStoreFixture(daemon: daemon)
    let store = fixture.makeStore()
    let question = try PuckPendingQuestion([
        "call_id": "question-1", "expires_at_ms": 0,
        "questions": [[
            "header": "Files", "question": "Which files?", "multiple": false,
            "custom": false,
            "options": [["label": "One", "description": "Use one file."]],
        ]],
    ])
    let summary = puckSummary(cwd: fixture.project.path, position: "parked", pendingQuestion: question)
    daemon.put(summary)
    store.openListedPuckSessions([summary])
    let session = try #require(store.sessions.first as? PuckSession)
    let gate = daemon.holdNextGet(after: 0)

    session.answer([PuckQuestionSelection(labels: ["One"])])
    try await waitForPuckState { daemon.answers.count == 1 }

    #expect(session.answerInFlight)
    #expect(session.pendingQuestion == nil)
    store.applyPuckSummaries([summary])
    #expect(session.pendingQuestion == nil)
    gate.signal()
    try await waitForPuckState { !session.answerInFlight }
    #expect(session.position == "running")
}
