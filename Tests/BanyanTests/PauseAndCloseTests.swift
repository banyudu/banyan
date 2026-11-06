import AppKit
import Combine
import BanyanCore
import Foundation
import Network
import Testing
@testable import Banyan


@MainActor
@Suite struct PauseAndCloseTests {
    func managed(_ store: SessionStore, state: SessionWorkflow.State = .waiting,
                         owner: String = "workit") throws -> BanyanSession {
        store.loadPersistedSessionsIfNeeded()
        try store.setWorkflow(id: "managed", workflow: .init(owner: owner, jobID: "job-a", revision: 3, state: state))
        return try #require(store.sessions.first { $0.id == "managed" })
    }

    func project(_ store: SessionStore, revision: Int = 4, state: SessionWorkflow.State = .paused) throws {
        try store.setWorkflow(id: "managed", workflow: .init(owner: "workit", jobID: "job-a", revision: revision, state: state))
    }

    @Test func idleAgentWithUnfinishedWorkflowDoesNotClaimToBeRunning() throws {
        let fixture = try WorkflowStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = fixture.makeStore()
        defer { store.flushPendingSessionSaves() }
        let session = try managed(store, state: .working)
        session.status = .needInput
        store.requestClose(id: session.id)

        #expect(store.pendingCloseTitle == "Close idle agent?")
        #expect(store.pendingCloseMessage.hasPrefix("The agent is waiting for input. Its workflow is still unfinished."))
        #expect(!store.pendingCloseMessage.contains("children running"))
        #expect(store.pendingCloseCanPause)
        #expect(store.canHideAndKeepWorking(session))
        #expect(throws: (any Error).self) { try store.close(id: session.id) }
        #expect(fixture.backend.killed.isEmpty)
        #expect(session.workflow?.state == .working)

        session.status = .executing
        #expect(store.pendingCloseTitle == "Close running agent?")
        #expect(!store.pendingCloseMessage.contains("The agent is waiting for input."))
    }

    @Test(arguments: SessionWorkflow.State.allCases)
    func actionPolicyAndOrdinaryClose(state: SessionWorkflow.State) throws {
        let fixture = try WorkflowStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = fixture.makeStore()
        defer { store.flushPendingSessionSaves() }
        let session = try managed(store, state: state)
        store.requestClose(id: session.id)
        #expect(store.pendingCloseCanPause == !state.permitsClose)
        #expect(store.pendingCloseSession === session)
        if state.permitsClose {
            #expect(!store.pendingCloseMessage.contains("Hold Command"))
            store.confirmPendingClose()
            #expect(session.status == .closed)
            #expect(session.workflow?.state == state)
        } else {
            #expect(throws: (any Error).self) { try store.close(id: session.id) }
            #expect(session.status != .closed)
            #expect(store.pendingCloseMessage.contains("leaves the issue unfinished"))
            #expect(store.pendingCloseMessage.contains("stops future automatic continuation"))
            #expect(store.pendingCloseMessage.contains("may terminate the current coding agent"))
            #expect(!store.pendingCloseMessage.contains("Hold Command"))
        }
        store.requestClose(id: "legacy")
        #expect(!store.pendingCloseCanPause)
        store.confirmPendingClose()
        #expect(store.sessions.first { $0.id == "legacy" }?.status == .closed)
    }

    @Test func durableAcknowledgementAndProjectionPrecedeOrdinaryCloseAndPreserveHistory() async throws {
        let fixture = try WorkflowStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let client = FakeWorkitPauseClient()
        let store = fixture.makeStore(pauseClient: client)
        defer { store.flushPendingSessionSaves() }
        let parent = try managed(store, state: .working)
        parent.status = .executing
        let child = try #require(store.sessions.first { $0.id == "legacy" })
        child.parentSessionID = parent.id
        store.requestClose(id: parent.id)
        #expect(store.pendingCloseHasOngoingAgent)
        #expect(store.pendingCloseHasActiveChildren)
        #expect(store.pendingCloseMessage.contains("tmux session"))
        #expect(store.pendingCloseMessage.contains("will be terminated"))
        #expect(store.pendingCloseMessage.contains("Child sessions will be detached"))
        client.onPause = { request in
            #expect(request.jobID == "job-a")
            #expect(request.expectedRevision == 3)
            #expect(request.sessionID == "managed")
            #expect(!request.detail.isEmpty)
            #expect(fixture.backend.killed.isEmpty)
            #expect(parent.workflow?.state == .working)
            try self.project(store)
            // Workit may project before its command returns; close is still held.
            #expect(throws: (any Error).self) { try store.close(id: parent.id) }
            #expect(fixture.backend.killed.isEmpty)
            return WorkitPausedJob(id: request.jobID, sessionID: request.sessionID, revision: 4, stage: "paused")
        }
        try await store.pauseAndClose(id: parent.id)
        #expect(parent.status == .closed)
        #expect(parent.workflow?.state == .paused)
        #expect(try store.workflowJournal.load(id: parent.id)?.state == .paused)
        #expect(fixture.backend.killed == ["banyan-managed"])
        #expect(child.parentSessionID == nil)
        #expect(child.status != .closed)
        #expect(store.sessions.contains { $0 === parent })
        store.flushPendingSessionSaves()
        #expect(fixture.persistence.load().first { $0.id == parent.id }?.status == .closed)
        #expect(client.requests.count == 1)
    }

    @Test func unsupportedOwnerAndUnreadableJournalNeverCallOwnerOrClose() async throws {
        for kind in ["owner", "recovery-error", "corrupt", "missing"] {
            let fixture = try WorkflowStoreFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let client = FakeWorkitPauseClient()
            let store = fixture.makeStore(pauseClient: client)
            defer { store.flushPendingSessionSaves() }
            let session = try managed(store, owner: kind == "owner" ? "other-owner" : "workit")
            if kind == "recovery-error" { session.workflowRecoveryError = "unreadable" }
            let journal = store.workflowJournal.directory.appendingPathComponent("managed.json")
            if kind == "corrupt" { try Data("{".utf8).write(to: journal) }
            if kind == "missing" { try FileManager.default.removeItem(at: journal) }
            store.requestClose(id: session.id)
            if ["owner", "recovery-error"].contains(kind) { #expect(!store.pendingCloseCanPause) }
            do {
                try await store.pauseAndClose(id: session.id)
                Issue.record("Expected pause refusal")
            } catch { #expect(error.localizedDescription.contains("workflow")) }
            #expect(session.status != .closed)
            #expect(client.requests.isEmpty)
            #expect(fixture.backend.killed.isEmpty)
        }
    }

    @Test(arguments: ["job", "session", "revision", "verified", "cancelled"])
    func invalidAcknowledgementRetainsSession(kind: String) async throws {
        let fixture = try WorkflowStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let client = FakeWorkitPauseClient()
        let store = fixture.makeStore(pauseClient: client)
        defer { store.flushPendingSessionSaves() }
        let session = try managed(store)
        client.onPause = { _ in
            WorkitPausedJob(id: kind == "job" ? "job-b" : "job-a",
                sessionID: kind == "session" ? "other-session" : "managed",
                revision: kind == "revision" ? 3 : 4,
                stage: ["verified", "cancelled"].contains(kind) ? kind : "paused")
        }
        await #expect(throws: (any Error).self) { try await store.pauseAndClose(id: session.id) }
        #expect(session.status != .closed)
        #expect(session.workflow?.state == .waiting)
        #expect(fixture.backend.killed.isEmpty)
    }

    @Test func duplicateClicksAndDelayedProjectionDoNotRepeatPause() async throws {
        let fixture = try WorkflowStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let client = FakeWorkitPauseClient()
        let store = fixture.makeStore(pauseClient: client, projectionTimeout: .seconds(5))
        defer { store.flushPendingSessionSaves() }
        let session = try managed(store)
        let first = Task { try await store.pauseAndClose(id: session.id) }
        try await waitForPuckState { store.pauseCloseAttempts[session.id]?.projectionWaiter != nil }
        #expect(store.pauseCloseInFlightIDs == [session.id])
        await #expect(throws: (any Error).self) { try await store.pauseAndClose(id: session.id) }
        #expect(session.status != .closed)
        #expect(fixture.backend.killed.isEmpty)
        // An idempotent replay of the original projection must not end the wait.
        try store.setWorkflow(id: session.id, workflow: try #require(session.workflow))
        await Task.yield()
        #expect(store.pauseCloseInFlightIDs.contains(session.id))
        try project(store)
        try await first.value
        #expect(client.requests.count == 1)
        #expect(fixture.backend.killed.count == 1)
    }

    @Test func durablePauseProjectionFailureRetainsReceiptAndRetryOnlyChecksProjection() async throws {
        let fixture = try WorkflowStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let client = FakeWorkitPauseClient()
        let store = fixture.makeStore(pauseClient: client)
        defer { store.flushPendingSessionSaves() }
        let session = try managed(store)
        do {
            try await store.pauseAndClose(id: session.id)
            Issue.record("Expected missing projection")
        } catch {
            #expect(error.localizedDescription.contains("durable pause"))
            #expect(error.localizedDescription.contains("terminal remains open"))
            #expect(error.localizedDescription.contains("control connection"))
        }
        #expect(session.status != .closed)
        #expect(session.workflow?.state == .waiting)
        #expect(fixture.backend.killed.isEmpty)
        #expect(store.pauseCloseAttempts[session.id]?.acknowledgement?.revision == 4)
        // More failed checks must not mutate Workit again.
        await #expect(throws: (any Error).self) { try await store.pauseAndClose(id: session.id) }
        #expect(client.requests.count == 1)
        try project(store)
        try await store.pauseAndClose(id: session.id)
        #expect(client.requests.count == 1)
        #expect(fixture.backend.killed.count == 1)
        #expect(session.workflow?.state == .paused)
    }

    @Test(arguments: ["revision", "job", "owner", "session", "restarted-session", "journal", "new-hold"])
    func changedBindingOrJournalRetainsSessionAndDoesNotClearHold(kind: String) async throws {
        let fixture = try WorkflowStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let client = FakeWorkitPauseClient()
        let store = fixture.makeStore(pauseClient: client)
        defer { store.flushPendingSessionSaves() }
        let session = try managed(store)
        client.onPause = { request in
            switch kind {
            case "revision": try self.project(store, revision: 4, state: .working)
            case "job": session.workflow = .init(owner: "workit", jobID: "job-b", revision: 4, state: .paused)
            case "owner": session.workflow = .init(owner: "other-owner", jobID: "job-a", revision: 4, state: .paused)
            case "session": session.command = "codex 'A different conversation'"
            case "restarted-session": (session as? TerminalSession)?.admissionGeneration = UUID()
            case "journal":
                try self.project(store)
                try Data("{".utf8).write(to: store.workflowJournal.directory.appendingPathComponent("managed.json"))
            default: try self.project(store, revision: 5, state: .needsYou)
            }
            return WorkitPausedJob(id: request.jobID, sessionID: request.sessionID, revision: 4, stage: "paused")
        }
        await #expect(throws: (any Error).self) { try await store.pauseAndClose(id: session.id) }
        await #expect(throws: (any Error).self) { try await store.pauseAndClose(id: session.id) }
        #expect(client.requests.count == 1)
        #expect(session.status != .closed)
        #expect(fixture.backend.killed.isEmpty)
        if kind == "new-hold" { #expect(session.workflow?.state == .needsYou) }
    }

    @Test func cliFailureRetainsSessionAndUIReportsActionableError() async throws {
        let fixture = try WorkflowStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let client = FakeWorkitPauseClient()
        let store = fixture.makeStore(pauseClient: client)
        defer { store.flushPendingSessionSaves() }
        let session = try managed(store)
        client.onPause = { _ in throw WorkflowError.refused("Upgrade the configured Workit CLI and retry.") }
        store.requestClose(id: session.id)
        store.confirmPendingPauseAndClose()
        try await waitForPuckState { store.pauseCloseError != nil }
        #expect(store.pauseCloseError?.contains("Upgrade") == true)
        #expect(store.pendingCloseSession == nil)
        #expect(session.status != .closed)
        #expect(fixture.backend.killed.isEmpty)
    }

    @Test func controlServerCanAcceptProjectionWhilePauseIsSuspended() async throws {
        let fixture = try WorkflowStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let client = FakeWorkitPauseClient()
        let store = fixture.makeStore(pauseClient: client, projectionTimeout: .seconds(5))
        defer { store.flushPendingSessionSaves() }
        let session = try managed(store)
        let server = ControlServer(store: store, host: store.host, port: .any)
        server.start()
        defer { server.stop() }
        try await waitForPuckState { server.listeningPort != nil }
        let port = try #require(server.listeningPort)
        let task = Task { try await store.pauseAndClose(id: session.id) }
        try await waitForPuckState { store.pauseCloseAttempts[session.id]?.projectionWaiter != nil }
        #expect(store.pauseCloseInFlightIDs.contains(session.id))
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/workflow-set")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 2
        request.setValue(try ControlToken.loadOrCreate(environment: store.host.environment,
            homeDirectory: store.host.homeDirectory), forHTTPHeaderField: ControlToken.headerName)
        request.httpBody = Data(#"{"id":"managed","owner":"workit","jobID":"job-a","revision":4,"state":"paused"}"#.utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        try await task.value
        #expect(session.status == .closed)
        #expect(client.requests.count == 1)
    }

    @Test(arguments: ["missing", "older", "nonzero"])
    func configuredCLIFailureRetainsSession(kind: String) async throws {
        let fixture = try WorkflowStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = fixture.makeStore()
        defer { store.flushPendingSessionSaves() }
        let session = try managed(store)
        let directory = fixture.root.appendingPathComponent(".banyan")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = fixture.root.appendingPathComponent("workit.py")
        try Data("import sys\nprint('Unknown option --expected-revision', file=sys.stderr)\nsys.exit(\(kind == "older" ? 1 : 17))".utf8).write(to: script)
        try JSONEncoder().encode(WorkitCommandPauseClient.Configuration(
            invocation: kind == "missing" ? [fixture.root.appendingPathComponent("missing-workit").path]
                : ["/usr/bin/python3", script.path], stateDirectory: fixture.root.appendingPathComponent("owner-state").path))
            .write(to: directory.appendingPathComponent("workit.json"))
        do {
            try await store.pauseAndClose(id: session.id)
            Issue.record("Expected CLI failure")
        } catch { #expect(error.localizedDescription.contains("Workit")) }
        #expect(session.status != .closed)
        #expect(session.workflow?.state == .waiting)
        #expect(fixture.backend.killed.isEmpty)
    }

    @Test func partialSuccessUIRetryAndNewHoldAreHonest() async throws {
        for newHold in [false, true] {
            let fixture = try WorkflowStoreFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let client = FakeWorkitPauseClient()
            let store = fixture.makeStore(pauseClient: client)
            defer { store.flushPendingSessionSaves() }
            let session = try managed(store)
            store.requestClose(id: session.id)
            store.confirmPendingPauseAndClose()
            // Reentry through the dialog handler has no second pending session.
            store.confirmPendingPauseAndClose()
            try await waitForPuckState { store.pauseCloseError != nil }
            #expect(store.pauseCloseRetrySessionID == session.id)
            #expect(store.pauseCloseError?.contains("durable pause") == true)
            #expect(session.status != .closed)
            try project(store, revision: newHold ? 5 : 4, state: newHold ? .needsYou : .paused)
            store.retryPauseAndClose()
            store.retryPauseAndClose()
            try await waitForPuckState { session.status == .closed || store.pauseCloseError != nil }
            #expect(client.requests.count == 1)
            #expect(session.status == (newHold ? .completed : .closed))
            #expect(session.workflow?.state == (newHold ? .needsYou : .paused))
            #expect(fixture.backend.killed.count == (newHold ? 0 : 1))
        }
    }

    @Test func ordinaryCloseAlsoRejectsACorruptedPausedJournal() throws {
        let fixture = try WorkflowStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = fixture.makeStore()
        defer { store.flushPendingSessionSaves() }
        let session = try managed(store, state: .paused)
        try Data("{".utf8).write(to: store.workflowJournal.directory.appendingPathComponent("managed.json"))
        store.requestClose(id: session.id)
        store.confirmPendingClose()
        #expect(store.pauseCloseError?.contains("journal") == true)
        #expect(store.pauseCloseRetrySessionID == nil)
        #expect(session.status != .closed)
        #expect(fixture.backend.killed.isEmpty)
    }

    @Test func ordinaryCloseAfterDelayedPauseDiscardsTheRetainedReceipt() async throws {
        let fixture = try WorkflowStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let client = FakeWorkitPauseClient()
        let store = fixture.makeStore(pauseClient: client)
        defer { store.flushPendingSessionSaves() }
        let session = try managed(store)
        store.requestClose(id: session.id)
        store.confirmPendingPauseAndClose()
        try await waitForPuckState { store.pauseCloseError != nil }
        #expect(store.pauseCloseAttempts[session.id]?.acknowledgement != nil)
        try project(store)
        store.requestClose(id: session.id)
        #expect(!store.pendingCloseCanPause)
        store.confirmPendingClose()
        #expect(session.status == .closed)
        #expect(store.pauseCloseAttempts[session.id] == nil)
        #expect(store.pauseCloseRetrySessionID == nil)
        #expect(client.requests.count == 1)
        #expect(fixture.backend.killed.count == 1)
    }
}
