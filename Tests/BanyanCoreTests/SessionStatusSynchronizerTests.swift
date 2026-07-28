import Foundation
import Testing
@testable import BanyanCore

@Test func statusSynchronizerUpdatesLiveShellState() {
    let backend = SynchronizerBackend()
    let now = Date(timeIntervalSince1970: 100)
    let snapshot = SessionSnapshot(
        id: "session-1",
        tmuxSessionName: nil,
        title: "Shell",
        reportedTitle: nil,
        cwd: "/tmp",
        command: "",
        status: .needInput,
        tone: .yellow,
        createdAt: now,
        updatedAt: now
    )
    let synchronizer = SessionStatusSynchronizer(
        backend: backend,
        processTable: ProcessTable(rows: [])
    )

    let result = synchronizer.synchronize([snapshot]).first!

    #expect(result.status == .running)
    #expect(result.tone == .blue)
    #expect(result.updatedAt > now)
    #expect(backend.requestedNames == [TmuxBackend.sessionName(for: "session-1")])
}

@Test func statusSynchronizerKeepsUnattachedRestoredSessionsAlive() {
    let backend = SynchronizerBackend()
    backend.hasBackingSession = false
    let input = SessionStatusObservationInput(
        id: "restored",
        tmuxSessionName: "banyan-restored",
        command: "codex",
        status: .running,
        isAwaitingAttach: true
    )
    let synchronizer = SessionStatusSynchronizer(
        backend: backend,
        processTable: ProcessTable(rows: [])
    )

    #expect(synchronizer.observe([input]).isEmpty)
}

private final class SynchronizerBackend: AgentSupervisorBackend, @unchecked Sendable {
    var requestedNames: [String] = []
    var hasBackingSession = true

    func hasSession(named name: String) -> Bool {
        requestedNames.append(name)
        return hasBackingSession
    }

    func primaryPaneSnapshot(named name: String) -> TmuxPaneSnapshot? {
        guard hasBackingSession else { return nil }
        return TmuxPaneSnapshot(
            paneID: "%0",
            rootPID: 100,
            currentCommand: "bash",
            currentPath: "/tmp",
            isDead: false,
            isInMode: false
        )
    }

    func captureVisibleText(paneID: String, lineLimit: Int) -> String { "" }
}
