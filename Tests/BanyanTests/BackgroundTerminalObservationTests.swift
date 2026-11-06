import Foundation
import BanyanCore
import Testing
@testable import Banyan

@MainActor @Suite struct BackgroundTerminalObservationTests {
    @Test func supervisorCountReachesTheRowAndClearsWithoutAStatusChange() throws {
        let fixture = try WorkflowStoreFixture(sessionIDs: ["managed"])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = fixture.makeStore()
        defer { store.flushPendingSessionSaves(); store.workOverviewRefreshTask?.cancel() }
        store.loadPersistedSessionsIfNeeded()
        let session = try #require(store.sessions.first as? TerminalSession)
        let pane = supervisorTestPane()
        fixture.backend.readablePane = pane
        fixture.backend.visibleText = "Done\n1 background terminal running · /ps to view · /stop to close\n› Ask Codex to do anything"
        let agent = supervisorTestAgentProcess("codex")
        let server = supervisorTestProcess(pid: 102, parentPID: 101,
            commandName: "node", arguments: "node dev-server.js", elapsed: 600)
        let input = SessionStatusObservationInput(id: session.id, tmuxSessionName: session.tmuxSessionName,
            command: "codex", status: .executing, isAwaitingAttach: false)
        func observe(_ processes: [ProcessInfoRow]) throws -> SessionStatusObservation {
            try #require(SessionStatusSynchronizer(backend: fixture.backend, processTable: ProcessTable(rows: processes))
                .observe([input], paneSnapshots: [session.tmuxSessionName: pane]).first)
        }
        let result = try observe([agent, server])
        #expect(result.backgroundTerminalCount == 1)
        store.applySupervisorResults([result])
        #expect(session.status == .needInput)
        #expect(session.statusHelp == "Need Input · 1 background terminal")
        let unchanged = session.updatedAt
        store.applySupervisorResults([try observe([agent])])
        #expect(session.backgroundTerminalCount == 0)
        #expect(session.status == .needInput)
        #expect(session.statusHelp == "Need Input")
        #expect(session.updatedAt == unchanged) // Badge-only changes are runtime state.
        session.backgroundTerminalCount = 1
        session.mark(status: .closed)
        #expect(session.backgroundTerminalCount == 0)
    }

    @Test func backgroundTerminalsPreventSuspensionAndVerifiedCleanup() async throws {
        let fixture = try WorkflowStoreFixture(sessionIDs: ["managed"])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = fixture.makeStore()
        defer { store.flushPendingSessionSaves(); store.workOverviewRefreshTask?.cancel() }
        store.loadPersistedSessionsIfNeeded()
        let session = try #require(store.sessions.first as? TerminalSession)
        store.selectedSessionID = nil
        store.selection.selectedSessionID = nil
        session.status = .idle
        session.backgroundTerminalCount = 1
        try store.setWorkflow(id: session.id, workflow: .init(owner: "workit", jobID: "job-a", revision: 1, state: .verified))
        #expect(!store.verifiedWorkflowSessionIDs.contains(session.id))
        #expect(try store.closeVerifiedWorkflows().isEmpty)
        await #expect(throws: (any Error).self) { try await store.freezeAgent(id: session.id) }
        await #expect(throws: (any Error).self) { try await store.deepSuspendAgent(id: session.id) }
        #expect(!session.isFrozen && !session.isDeepSuspended)
        #expect(fixture.backend.killed.isEmpty)
        session.backgroundTerminalCount = 0
        #expect(store.verifiedWorkflowSessionIDs.contains(session.id))
    }
}
