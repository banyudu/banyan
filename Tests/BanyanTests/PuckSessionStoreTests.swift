import BanyanCore
import Foundation
import Testing
@testable import Banyan

/// A puck session is a session like any other: it sits in the same list, with
/// the same status, close, and "new session like this one" behavior. Only the
/// runtime behind it differs, and these tests pin where it does.

@MainActor
@Test func daemonListingAddsPuckSessionsToTheSessionList() throws {
    let daemon = FakePuckDaemon()
    let fixture = try PuckStoreFixture(daemon: daemon)
    let store = fixture.makeStore()
    store.loadPersistedSessionsIfNeeded()
    daemon.put(puckSummary(model: "gpt-5.5", cwd: fixture.project.path, position: "running"))

    store.applyPuckSummaries(try daemon.list())

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
}

@MainActor
@Test func daemonListingDrivesPuckSessionStatus() throws {
    let daemon = FakePuckDaemon()
    let fixture = try PuckStoreFixture(daemon: daemon)
    let store = fixture.makeStore()
    let summary = puckSummary(cwd: fixture.project.path, position: "running")
    store.applyPuckSummaries([summary])
    let session = try #require(store.sessions.first)

    store.applyPuckSummaries([summary.with(position: "idle", historyItems: 1)])
    #expect(session.status == .needInput)
    #expect(session.tone == .yellow)

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
    store.applyPuckSummaries([puckSummary(cwd: fixture.project.path, position: "running")])
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
    store.applyPuckSummaries([summary])
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
@Test func removedPuckSessionsStayRemovedUntilTheDaemonForgetsThem() throws {
    let daemon = FakePuckDaemon()
    let fixture = try PuckStoreFixture(daemon: daemon)
    let summary = puckSummary(cwd: fixture.project.path)
    daemon.put(summary)
    let store = fixture.makeStore()
    store.loadPersistedSessionsIfNeeded()
    store.applyPuckSummaries(try daemon.list())

    try store.remove(id: summary.id)
    store.applyPuckSummaries(try daemon.list())
    #expect(store.sessions.isEmpty)

    // Across a relaunch too.
    store.flushPendingSessionSaves()
    let relaunched = fixture.makeStore()
    relaunched.loadPersistedSessionsIfNeeded()
    relaunched.applyPuckSummaries(try daemon.list())
    #expect(relaunched.sessions.isEmpty)

    // Once the daemon drops it, the dismissal has nothing left to hide.
    daemon.forget(summary.id)
    relaunched.applyPuckSummaries(try daemon.list())
    daemon.put(summary)
    relaunched.applyPuckSummaries(try daemon.list())
    #expect(relaunched.sessions.map(\.id) == [summary.id])
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
    store.applyPuckSummaries([summary])
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
    store.applyPuckSummaries([puckSummary(cwd: fixture.project.path)])
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
    store.applyPuckSummaries([puckSummary(cwd: fixture.project.path)])
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
    store.applyPuckSummaries([summary])
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
    try await waitForPuckState { session.status == .needInput }
    #expect(session.events.map(\.cursor) == [1, 2])

    // A dropped stream shows as lost, and following again reattaches.
    daemon.dropFollower(session.id)
    try await waitForPuckState { session.followState == .lost }
    session.startFollowing()
    try await waitForPuckState { session.followState == .following }

    session.stopFollowing()
    #expect(session.followState == .stopped)
    #expect(session.events.isEmpty)
    try await waitForPuckState { !daemon.isFollowed(session.id) }
}

@MainActor
@Test func puckSessionsSayWhyTheyCannotTakeATurn() throws {
    let daemon = FakePuckDaemon()
    let fixture = try PuckStoreFixture(daemon: daemon)
    let store = fixture.makeStore()
    let summary = puckSummary(cwd: fixture.project.path)
    store.applyPuckSummaries([summary])
    let session = try #require(store.sessions.first as? PuckSession)
    #expect(session.turnUnavailableReason == nil)

    store.applyPuckSummaries([summary.with(position: "running")])
    #expect(session.turnUnavailableReason != nil)

    let approval = PuckPendingApproval(callID: "call-1", tool: "shell", arguments: "ls", expiresAtMS: 0)
    store.applyPuckSummaries([summary.with(position: "parked", pendingApproval: .some(approval))])
    #expect(session.turnUnavailableReason != nil)
}
