import Foundation
import Testing
@testable import Banyan
@testable import BanyanCore

@MainActor
@Test func supervisorOutputBurstPreservesActivityAndInputInvalidation() throws {
    let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
    fixture.persistence.save((0..<50).map { index in
        SessionSnapshot(id: "stream-\(index)", tmuxSessionName: nil, title: "Output fixture",
                        reportedTitle: nil, cwd: fixture.project.path, command: "codex",
                        status: .executing, tone: .blue, createdAt: Date(), updatedAt: Date())
    })
    let store = fixture.makeStore(sessionBackend: AdmissionTerminalBackend())
    store.loadPersistedSessionsIfNeeded()
    let session = try #require(store.sessions.last as? TerminalSession)
    let output = try #require(session.onOutput)
    let before = store.supervisorObservationStates[session.id] ?? .init()
    let start = Date()

    for _ in 0..<2000 { output("working ") }

    let after = try #require(store.supervisorObservationStates[session.id])
    #expect(after.revision == before.revision + 2000)
    #expect(after.resultRevision == before.resultRevision)
    #expect(after.stableObservations == 0)
    #expect(after.nextDueAt <= start)
    #expect(after.fastUntil > start)
    #expect(store.pendingSupervisorActivityIDs.contains(session.id))
    #expect(store.terminalSessions.allSatisfy { $0.loadedTerminalView == nil })

    session.onUserSubmittedInput?(nil)
    #expect(store.supervisorObservationStates[session.id]?.resultRevision == before.resultRevision + 1)
}

@MainActor
@Test(arguments: ["closed", "suspended", "frozen", "deep-suspended"])
func supervisorOutputDoesNotWakeInactiveSessions(lifecycle: String) throws {
    let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
    let store = fixture.makeStore(sessionBackend: AdmissionTerminalBackend())
    let session = TerminalSession(id: "inactive", title: "Output fixture", cwd: fixture.project.path,
                                  command: "codex", theme: .system, tmuxBackend: AdmissionTerminalBackend(),
                                  telemetry: banyanTestTelemetry, host: banyanTestHost)
    switch lifecycle {
    case "closed": session.status = .closed
    case "suspended": session.isSuspended = true
    case "frozen": session.isFrozen = true
    default: session.isDeepSuspended = true
    }
    store.resetSupervisorObservationBackoff(for: session, invalidatesObservation: false)
    #expect(store.supervisorObservationStates.isEmpty)
    #expect(store.pendingSupervisorActivityIDs.isEmpty)
}
