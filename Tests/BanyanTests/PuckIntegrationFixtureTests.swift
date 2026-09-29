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
