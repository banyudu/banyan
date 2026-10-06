import BanyanCore
import Foundation
import Testing
@testable import Banyan

@Test @MainActor func puckPresenceFollowsInputAndImmediateAwaySignals() {
    let observation = FakePuckObservation()
    let monitor = PuckPresenceMonitor()
    monitor.observe(observation)
    #expect(observation.presenceReports == [false])
    monitor.setFrontmost(true)
    #expect(observation.presenceReports.last == true)
    let now = Date()
    monitor.activity(now: now)
    let count = observation.presenceReports.count
    monitor.activity(now: now.addingTimeInterval(0.1))
    #expect(observation.presenceReports.count == count)

    monitor.setScreenLocked(true)
    monitor.activity(now: now.addingTimeInterval(2))
    #expect(observation.presenceReports.last == false)
    monitor.setScreenLocked(false)
    #expect(observation.presenceReports.last == false)
    monitor.activity(now: now.addingTimeInterval(3))
    #expect(observation.presenceReports.last == true)

    monitor.setDisplayAsleep(true)
    monitor.setFrontmost(true)
    #expect(observation.presenceReports.last == false)
    monitor.setDisplayAsleep(false)
    #expect(observation.presenceReports.last == false)
    monitor.activity(now: now.addingTimeInterval(4))
    #expect(observation.presenceReports.last == true)
    monitor.setFrontmost(false)
    monitor.activity(now: now.addingTimeInterval(5))
    #expect(observation.presenceReports.last == false)
    monitor.stop()
}

@Test @MainActor func puckWatchUpdatesOffscreenSessionsAndReconnects() async throws {
    let daemon = FakePuckDaemon()
    let fixture = try PuckStoreFixture(daemon: daemon)
    let store = fixture.makeStore()
    defer { store.stopPuckObservation() }
    let summary = puckSummary(cwd: fixture.project.path)
    daemon.put(summary)
    store.startPuckObservation()
    try await waitForPuckState { store.sessions.count == 1 }
    let session = try #require(store.sessions.first as? PuckSession)
    #expect(!daemon.isFollowed(session.id))
    daemon.publishWatch(.snapshot([summary.with(position: "running")]))
    try await waitForPuckState { session.status == .executing }

    daemon.put(summary.with(position: "idle", historyItems: 2))
    daemon.dropWatchers()
    try await waitForPuckState { daemon.watchCount >= 2 && session.status == .needInput }
    #expect(store.sessions.count == 1)
    #expect(session.events.isEmpty)
    #expect(!daemon.isFollowed(session.id))
}

@Test @MainActor func puckFollowResumesAutomaticallyAndDetachCancelsRecovery() async throws {
    let daemon = FakePuckDaemon()
    let fixture = try PuckStoreFixture(daemon: daemon)
    let store = fixture.makeStore()
    let summary = puckSummary(cwd: fixture.project.path)
    daemon.put(summary, transcript: [PuckSessionEvent(cursor: 1, kind: "turn_done", text: "one")])
    store.applyPuckSummaries([summary])
    let session = try #require(store.sessions.first as? PuckSession)
    session.startFollowing()
    defer { session.stopFollowing() }
    try await waitForPuckState { session.followState == .following }
    daemon.dropFollower(session.id)
    try await waitForPuckState { session.followState == .lost }
    daemon.put(summary, transcript: [
        PuckSessionEvent(cursor: 1, kind: "turn_done", text: "one"),
        PuckSessionEvent(cursor: 2, kind: "turn_done", text: "two")
    ])
    try await waitForPuckState { session.followState == .following && session.events.count == 2 }
    #expect(session.events.map(\.cursor) == [1, 2])
    daemon.dropFollower(session.id)
    try await waitForPuckState { session.followState == .lost }
    session.stopFollowing()
    try await Task.sleep(for: .milliseconds(1200))
    #expect(session.followState == .stopped)
    #expect(!daemon.isFollowed(session.id))
}

@Test @MainActor func puckWatchSnapshotsDoNotUndoCreatesOrDismissals() async throws {
    let daemon = FakePuckDaemon()
    let fixture = try PuckStoreFixture(daemon: daemon)
    let store = fixture.makeStore()
    defer { store.stopPuckObservation() }
    let summary = puckSummary(cwd: fixture.project.path)
    daemon.put(summary)
    store.startPuckObservation()
    try await waitForPuckState { store.sessions.count == 1 }
    let created = try await store.createPuckSession(
        binding: PuckSessionBinding(provider: "codex"), cwd: fixture.project.path)
    daemon.publishWatch(.snapshot([summary.with(position: "running")]))
    try await waitForPuckState { (store.sessions.first { $0.id == summary.id } as? PuckSession)?.position == "running" }
    #expect(created.status != .closed)

    try store.remove(id: summary.id)
    daemon.publishWatch(.snapshot([]))
    daemon.publishWatch(.snapshot([summary, try daemon.get(created.id).with(position: "running")]))
    try await waitForPuckState { created.position == "running" }
    #expect(store.sessions.map(\.id) == [created.id])
    // A cancelled observer finishing after an immediate restart must not clear
    // the replacement connection or stop its updates.
    store.stopPuckObservation()
    store.startPuckObservation()
    try await waitForPuckState { daemon.watchCount == 2 }
    daemon.publishWatch(.snapshot([try daemon.get(created.id).with(position: "parked")]))
    try await waitForPuckState { created.position == "parked" }
    #expect(store.sessions.map(\.id) == [created.id])
}
