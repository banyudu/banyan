@testable import Banyan
import BanyanCore
import Foundation
import Testing

/// Invoked by scripts/verify-puck-integration.py against a real local puckd.
/// Ordinary test runs skip this because no fixture session is configured.
@Test @MainActor func appPuckSessionSeesSharedDaemonSessionAndItsEvents() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let id = environment["BANYAN_PUCK_E2E_SESSION"],
          let cursorText = environment["BANYAN_PUCK_E2E_AFTER_CURSOR"],
          let priorCursor = UInt64(cursorText) else { return }
    // The daemon the script started, found through `PUCK_HOME`.
    let fixture = try PuckStoreFixture(daemon: PuckDaemonClient())
    let store = fixture.makeStore()
    store.syncPuckSessions()
    try await waitForPuckFixture {
        store.sessions.contains(where: { $0.id == id })
    }
    let session = try #require(store.sessions.first(where: { $0.id == id }) as? PuckSession)
    session.startFollowing()
    try await waitForPuckFixture {
        session.followState == .following
    }
    if let readyFile = environment["BANYAN_PUCK_E2E_READY_FILE"] {
        try "ready".write(toFile: readyFile, atomically: true, encoding: .utf8)
    }
    try await waitForPuckFixture(timeout: .seconds(30)) {
        session.events.contains(where: { $0.cursor > priorCursor && $0.kind == "turn_done" })
    }
    #expect(session.backendKind == .puck)
    #expect(session.events.contains(where: {
        $0.cursor > priorCursor && $0.displayText?.contains("fixture done") == true
    }))
    session.stopFollowing()
}

@Test @MainActor func appPuckSessionAnswersParkedQuestion() async throws {
    guard let id = ProcessInfo.processInfo.environment["BANYAN_PUCK_E2E_QUESTION_SESSION"] else { return }
    let daemon = PuckDaemonClient()
    let direct = try daemon.get(id)
    #expect(direct.pendingQuestion?.callID == "question-1")
    let fixture = try PuckStoreFixture(daemon: daemon)
    let store = fixture.makeStore()
    store.syncPuckSessions()
    try await waitForPuckFixture {
        (store.sessions.first(where: { $0.id == id }) as? PuckSession)?.pendingQuestion?.callID == "question-1"
    }
    let session = try #require(store.sessions.first(where: { $0.id == id }) as? PuckSession)
    // A parked question is the user's to answer, like a terminal agent's prompt.
    #expect(session.status == .asking)
    let pending = try #require(session.pendingQuestion)
    #expect(pending.questions.first?.options.map(\.label) == ["Approve", "Deny"])
    try await waitForPuckFixture { session.questionPlan?.contains("Inspect the workspace") == true }
    session.startFollowing()
    session.answer([PuckQuestionSelection(labels: ["Approve"])])
    try await waitForPuckFixture {
        session.events.contains(where: { $0.kind == "turn_done" })
            && session.pendingQuestion == nil
    }
    session.stopFollowing()
}

@MainActor
private func waitForPuckFixture(
    timeout: Duration = .seconds(10),
    until condition: () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now >= deadline {
            throw PuckFixtureError.timedOut
        }
        try await Task.sleep(for: .milliseconds(50))
    }
}

private enum PuckFixtureError: Error {
    case timedOut
}

/// The process fixture drives two asks on the same session and measures Slack
/// delivery around an actual app-client presence transition.
@Test @MainActor func appPuckPresenceRoutesDeskThenAway() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let id = env["BANYAN_PUCK_E2E_PRESENCE_SESSION"],
          let ready = env["BANYAN_PUCK_E2E_PRESENCE_READY"],
          let awayTrigger = env["BANYAN_PUCK_E2E_AWAY_TRIGGER"],
          let awayReady = env["BANYAN_PUCK_E2E_AWAY_READY"] else { return }
    let daemon = PuckDaemonClient()
    let fixture = try PuckStoreFixture(daemon: daemon)
    let store = fixture.makeStore()
    store.startPuckObservation()
    defer { store.stopPuckObservation() }
    try await waitForPuckFixture { store.sessions.contains(where: { $0.id == id }) }
    let session = try #require(store.sessions.first(where: { $0.id == id }) as? PuckSession)
    session.startFollowing()
    defer { session.stopFollowing() }
    try await waitForPuckFixture { session.followState == .following }
    store.puckPresenceMonitor?.setFrontmost(true)
    try await waitForDaemonPresence(daemon, present: true)
    try "ready".write(toFile: ready, atomically: true, encoding: .utf8)
    try await waitForPuckFixture(timeout: .seconds(30)) {
        session.events.contains { $0.kind == "blocked_on_question" && $0.route == "interactive" && $0.notify == false }
            && session.pendingQuestion != nil
    }
    try await waitForPuckFixture(timeout: .seconds(30)) { FileManager.default.fileExists(atPath: awayTrigger) }
    store.puckPresenceMonitor?.setDisplayAsleep(true)
    try await waitForDaemonPresence(daemon, present: false)
    try "away".write(toFile: awayReady, atomically: true, encoding: .utf8)
    try await waitForPuckFixture(timeout: .seconds(30)) {
        session.events.contains { $0.kind == "blocked_on_question" && $0.route == "notify" && $0.notify == true }
            && session.pendingQuestion?.callID == "question-2"
    }
    #expect(session.backendKind == .puck)
}

@MainActor
private func waitForDaemonPresence(_ daemon: PuckDaemonClient, present: Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
        let actual = try await Task.detached {
            let value = try PuckDaemonConnection(socketPath: daemon.socketPath).request("presence.get")
            return (value as? [String: Any])?["present"] as? Bool
        }.value
        if actual == present { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw PuckFixtureError.timedOut
}

@Test @MainActor func appPuckReattachesAfterDaemonRestart() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let id = env["BANYAN_PUCK_E2E_RECONNECT_SESSION"],
          let ready = env["BANYAN_PUCK_E2E_RECONNECT_READY"],
          let lost = env["BANYAN_PUCK_E2E_RECONNECT_LOST"],
          let resumed = env["BANYAN_PUCK_E2E_RECONNECT_RESUMED"] else { return }
    let fixture = try PuckStoreFixture(daemon: PuckDaemonClient())
    let store = fixture.makeStore()
    store.startPuckObservation()
    defer { store.stopPuckObservation() }
    try await waitForPuckFixture { store.sessions.contains(where: { $0.id == id }) }
    let session = try #require(store.sessions.first(where: { $0.id == id }) as? PuckSession)
    session.startFollowing()
    defer { session.stopFollowing() }
    try await waitForPuckFixture { session.followState == .following }
    let cursors = session.events.map(\.cursor)
    let last = try #require(cursors.last)
    try "ready".write(toFile: ready, atomically: true, encoding: .utf8)
    try await waitForPuckFixture { session.followState == .lost }
    try "lost".write(toFile: lost, atomically: true, encoding: .utf8)
    try await waitForPuckFixture(timeout: .seconds(30)) { session.followState == .following }
    #expect(session.events.map(\.cursor) == cursors)
    #expect(store.sessions.filter { $0.id == id }.count == 1)
    try "resumed".write(toFile: resumed, atomically: true, encoding: .utf8)
    try await waitForPuckFixture {
        session.events.contains { $0.cursor > last && $0.kind == "turn_done" }
            && session.status == .needInput
    }
}
