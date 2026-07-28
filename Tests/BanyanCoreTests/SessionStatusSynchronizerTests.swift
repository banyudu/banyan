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
        processDescendants: { _ in [] }
    )

    let result = synchronizer.synchronize([snapshot]).first!

    #expect(result.status == .running)
    #expect(result.tone == .blue)
    #expect(result.updatedAt > now)
    #expect(backend.requestedNames == [TmuxBackend.sessionName(for: "session-1")])
}

private final class SynchronizerBackend: AgentSupervisorBackend, @unchecked Sendable {
    var requestedNames: [String] = []

    func hasSession(named name: String) -> Bool {
        requestedNames.append(name)
        return true
    }

    func primaryPaneSnapshot(named name: String) -> TmuxPaneSnapshot? {
        TmuxPaneSnapshot(
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
