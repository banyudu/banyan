import AppKit
import BanyanCore
import Foundation
import Network
import Testing
@testable import Banyan

@MainActor
@Suite struct SessionWorkflowStoreTests {
    @Test func restoredCompletedAgentCannotReplayItsInitialPromptWithoutAResumeTarget() throws {
        for sourceID in [nil, "", "unresumable"] as [String?] {
            let fixture = try WorkflowStoreFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let store = fixture.makeStore(history: WorkflowTestHistory(supportsResume: false))
            defer { store.flushPendingSessionSaves() }
            store.loadPersistedSessionsIfNeeded()
            let terminal = try #require(store.sessions.first { $0.id == "managed" } as? TerminalSession)
            terminal.agentSessionID = sourceID
            try store.setWorkflow(id: terminal.id, workflow: .init(owner: "workit", jobID: "job-a", revision: 0, state: .needsYou))
            #expect(terminal.needsRecovery)
            #expect(terminal.needsManualAttach)
            terminal.startBackgroundBackendIfNeeded()
            terminal.start()
            terminal.recoverFromMissingBackingSession()
            terminal.recoverFromMissingBackingSessionInBackground()
            #expect(throws: (any Error).self) { try store.recover(id: terminal.id) }
            #expect(terminal.status == .completed)
            #expect(terminal.needsRecovery)
            #expect(terminal.command.contains("Original implementation prompt"))
            #expect(!terminal.isProcessStarted)
            #expect(fixture.backend.launched.isEmpty)
            #expect(store.historyResumeError(id: terminal.id)?.contains("original command was not restarted") == true)
        }
    }

    @Test func completedAgentRecoveryResumesTheRecordedConversationWithoutTheInitialPrompt() async throws {
        let fixture = try WorkflowStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = fixture.makeStore()
        defer { store.flushPendingSessionSaves() }
        store.loadPersistedSessionsIfNeeded()
        let terminal = try #require(store.sessions.first { $0.id == "managed" } as? TerminalSession)
        terminal.agentSessionID = "11111111-2222-3333-4444-555555555555"
        try store.recover(id: terminal.id, select: false)
        try await waitForPuckState { terminal.isProcessStarted }
        #expect(terminal.command.contains("resume"))
        #expect(terminal.command.contains(terminal.agentSessionID!))
        #expect(!terminal.command.contains("Original implementation prompt"))
        #expect(!terminal.needsRecovery)
        #expect(fixture.backend.launched.allSatisfy { $0.contains("resume") && !$0.contains("Original implementation prompt") })
    }

    @Test func restoredAgentWhoseBackendDisappearedAfterStartupDoesNotReplayItsPrompt() async throws {
        let fixture = try WorkflowStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = fixture.makeStore()
        defer { store.flushPendingSessionSaves() }
        store.loadPersistedSessionsIfNeeded()
        let terminal = try #require(store.sessions.first { $0.id == "managed" } as? TerminalSession)
        // Startup saw a live pane, which vanished before the first selection.
        terminal.needsRecovery = false
        terminal.status = .needInput
        terminal.startBackgroundBackendIfNeeded()
        try await waitForPuckState { terminal.needsRecovery }
        #expect(terminal.needsManualAttach)
        #expect(!terminal.isProcessStarted)
        #expect(fixture.backend.launched.isEmpty)
        #expect(terminal.command.contains("Original implementation prompt"))
    }

    @Test func restoredAgentAttachmentNeverUsesTheBackingCreationPath() async throws {
        let fixture = try WorkflowStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = fixture.makeStore()
        defer { store.flushPendingSessionSaves() }
        store.loadPersistedSessionsIfNeeded()
        let terminal = try #require(store.sessions.first { $0.id == "managed" } as? TerminalSession)
        terminal.needsRecovery = false
        terminal.status = .needInput
        fixture.backend.observedPane = TmuxPaneSnapshot(paneID: "%existing", rootPID: 42,
            currentCommand: "codex", currentPath: fixture.root.path, isDead: false, isInMode: false)
        terminal.startBackgroundBackendIfNeeded()
        try await waitForPuckState { terminal.isProcessStarted }
        #expect(!terminal.needsRecovery)
        #expect(fixture.backend.launched.isEmpty)
    }

    @Test func restoreSeparatesProcessCompletionFromIssueCompletionAndProtectsClose() throws {
        let fixture = try WorkflowStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = fixture.makeStore()
        defer { store.flushPendingSessionSaves() }
        store.loadPersistedSessionsIfNeeded()
        try store.setWorkflow(id: "managed", workflow: .init(owner: "workit", jobID: "job-a", revision: 0, state: .waiting))
        let restored = fixture.makeStore()
        restored.loadPersistedSessionsIfNeeded()
        let managed = try #require(restored.sessions.first { $0.id == "managed" })
        #expect(managed.status == .completed)
        #expect(managed.workflow?.state == .waiting)
        restored.applySupervisorResults([SessionStatusObservation(id: "managed", status: .closed,
            tone: .neutral, provider: .codex, currentPath: nil)])
        #expect(managed.status == .completed)
        #expect(managed.needsRecovery)
        #expect(throws: (any Error).self) { try restored.close(id: "managed") }
        #expect(managed.status == .completed)
        #expect(restored.sessions.first { $0.id == "legacy" }?.workflow == nil)
    }

    @Test func bulkCloseSelectsOnlyVerifiedQuietSessions() throws {
        let fixture = try WorkflowStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = fixture.makeStore()
        defer { store.flushPendingSessionSaves() }
        store.loadPersistedSessionsIfNeeded()
        try store.setWorkflow(id: "managed", workflow: .init(owner: "workit", jobID: "job-a", revision: 0, state: .verified))
        try store.setWorkflow(id: "busy", workflow: .init(owner: "workit", jobID: "job-b", revision: 0, state: .verified))
        #expect(store.verifiedWorkflowSessionIDs == ["managed"])
        #expect(try store.closeVerifiedWorkflows() == ["managed"])
        #expect(store.sessions.first { $0.id == "legacy" }?.status == .completed)
        #expect(store.sessions.first { $0.id == "busy" }?.status == .executing)
    }

    @Test func receiptsSurviveStoreRestartAndNeedExplicitReconciliation() async throws {
        let fixture = try WorkflowStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = fixture.makeStore()
        defer { store.flushPendingSessionSaves() }
        store.loadPersistedSessionsIfNeeded()
        let pending = SessionWorkflow(owner: "workit", jobID: "job-a", revision: 3, state: .waiting,
            wake: .init(id: "wake-a", status: .pending))
        try store.setWorkflow(id: "managed", workflow: pending)
        let restored = fixture.makeStore()
        restored.loadPersistedSessionsIfNeeded()
        await #expect(throws: (any Error).self) {
            try await restored.wakeWorkflow(id: "managed", jobID: "job-a", revision: 3, wakeID: "wake-a", text: "Continue")
        }
        #expect(fixture.backend.sent.isEmpty)
        try restored.resolveWorkflowWake(id: "managed", jobID: "job-a", revision: 3, wakeID: "wake-a",
            outcome: "delivered", detail: "Original conversation inspected")
        try await restored.wakeWorkflow(id: "managed", jobID: "job-a", revision: 3, wakeID: "wake-a", text: "Continue")
        #expect(fixture.backend.sent.isEmpty)
    }

    @Test func unavailableConversationIdentityNeverReplaysTheOriginalCommand() async throws {
        let fixture = try WorkflowStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = fixture.makeStore()
        defer { store.flushPendingSessionSaves() }
        store.loadPersistedSessionsIfNeeded()
        try store.setWorkflow(id: "managed", workflow: .init(owner: "workit", jobID: "job-a", revision: 0, state: .working))
        await #expect(throws: (any Error).self) {
            try await store.wakeWorkflow(id: "managed", jobID: "job-a", revision: 0, wakeID: "wake-a", text: "Continue")
        }
        #expect(fixture.backend.sent.isEmpty)
        #expect(fixture.backend.launched.isEmpty)
    }

    @Test func missingPaneResumesTheRecordedConversationAndDeduplicates() async throws {
        let fixture = try WorkflowStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sourceID = "11111111-2222-3333-4444-555555555555"
        let history = WorkflowTestHistory(candidates: [.init(provider: .codex, sourceID: sourceID,
            cwd: fixture.root.path, createdAt: Date(), updatedAt: Date())])
        let store = fixture.makeStore(history: history)
        defer { store.flushPendingSessionSaves() }
        store.loadPersistedSessionsIfNeeded()
        let terminal = try #require(store.sessions.first { $0.id == "managed" } as? TerminalSession)
        terminal.agentSessionID = sourceID
        try store.setWorkflow(id: "managed", workflow: .init(owner: "workit", jobID: "job-a", revision: 0, state: .working))
        try await store.wakeWorkflow(id: "managed", jobID: "job-a", revision: 0, wakeID: "wake-a", text: "Continue verification")
        #expect(terminal.command.contains("resume"))
        #expect(terminal.command.contains(sourceID))
        #expect(terminal.command.contains("Continue verification"))
        #expect(!terminal.command.contains("Original implementation prompt"))
        #expect(terminal.workflow?.wake?.status == .delivered)
        let command = terminal.command
        try await store.wakeWorkflow(id: "managed", jobID: "job-a", revision: 0, wakeID: "wake-a", text: "Duplicate")
        #expect(terminal.command == command)
    }

    @Test func aReplacementPaneDuringHistoryLookupBlocksRecovery() async throws {
        let fixture = try WorkflowStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sourceID = "11111111-2222-3333-4444-555555555555"
        let history = WorkflowTestHistory(candidates: [.init(provider: .codex, sourceID: sourceID,
            cwd: fixture.root.path, createdAt: Date(), updatedAt: Date())])
        let store = fixture.makeStore(history: history)
        defer { store.flushPendingSessionSaves() }
        store.loadPersistedSessionsIfNeeded()
        let terminal = try #require(store.sessions.first { $0.id == "managed" } as? TerminalSession)
        terminal.agentSessionID = sourceID
        try store.setWorkflow(id: "managed", workflow: .init(owner: "workit", jobID: "job-a", revision: 0, state: .working))
        fixture.backend.replacementAfterFirstInspection = TmuxPaneSnapshot(paneID: "%new", rootPID: 42,
            currentCommand: "codex", currentPath: fixture.root.path, isDead: false, isInMode: false)
        await #expect(throws: (any Error).self) {
            try await store.wakeWorkflow(id: "managed", jobID: "job-a", revision: 0, wakeID: "wake-a", text: "Continue")
        }
        #expect(terminal.workflow?.wake == nil)
        #expect(terminal.command.contains("Original implementation prompt"))
        #expect(fixture.backend.launched.isEmpty)
    }
}

@MainActor
private struct WorkflowStoreFixture {
    let root: URL
    let persistence: SessionPersistence
    let backend = WorkflowTestBackend()
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("banyan-workflow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        persistence = SessionPersistence(databaseURL: root.appendingPathComponent("state.sqlite"),
            legacyJSONURL: root.appendingPathComponent("sessions.json"))
        let now = Date()
        persistence.save(["managed", "legacy", "busy"].map { id in
            SessionSnapshot(id: id, tmuxSessionName: "banyan-\(id)", title: id, reportedTitle: nil,
                cwd: root.path, command: "codex 'Original implementation prompt'", status: id == "busy" ? .executing : .completed,
                tone: .neutral, createdAt: now, updatedAt: now)
        })
    }
    func makeStore(history: WorkflowTestHistory = WorkflowTestHistory(),
                   pauseClient: (any WorkitPauseClient)? = nil,
                   projectionTimeout: Duration = .milliseconds(50)) -> SessionStore {
        _ = NSApplication.shared
        return SessionStore(persistence: persistence, tmuxBackend: backend, sessionBackend: backend,
            processTable: WorkflowTestProcesses(), historyBackend: history,
            detector: AgentStateDetector(rules: []),
            host: HostRuntimeContext(environment: ["BANYAN_FIXTURE_DATA_HOME": root.path, "PATH": "/usr/bin:/bin", "SHELL": "/bin/zsh"],
                homeDirectory: root, currentDirectory: root.path),
            telemetry: banyanTestTelemetry, attentionNotifier: AttentionNotifier(),
            workitPauseClient: pauseClient, pauseCloseProjectionTimeout: projectionTimeout)
    }
}

private final class WorkflowTestBackend: TmuxSessionStoreBackend, TmuxClientBackend, @unchecked Sendable {
    var sent: [String] = []
    var launched: [String] = []
    var killed: [String] = []
    var replacementAfterFirstInspection: TmuxPaneSnapshot?
    var observedPane: TmuxPaneSnapshot?
    private var inspections = 0
    var executableURL: URL { URL(fileURLWithPath: "/usr/bin/false") }
    func attachArguments(for name: String) -> [String] { [] }
    func hasSession(named name: String) -> Bool { false }
    func agentAdmissionPane(named name: String) -> AgentAdmissionPaneInspection {
        inspections += 1
        if inspections > 1, let replacementAfterFirstInspection { return .present(replacementAfterFirstInspection) }
        if let observedPane { return .present(observedPane) }
        return .absent
    }
    func primaryPaneSnapshot(named name: String) -> TmuxPaneSnapshot? { nil }
    func captureVisibleText(paneID: String, lineLimit: Int) -> String { "" }
    func captureCurrentVisibleText(paneID: String) -> String { "" }
    func listBanyanSessions() -> [String] { [] }
    func ensureSession(named name: String, cwd: String, command: String, banyanSessionID: String?) throws { launched.append(command) }
    func killSession(named name: String) { killed.append(name) }
    func sendKeys(paneID: String, keys: [TmuxKey]) throws { sent.append("keys") }
    func sendLiteral(paneID: String, text: String) throws { sent.append(text) }
    func configureTerminalTheme(style: String, for sessionName: String?) {}
    func refreshClients(attachedTo name: String) {}
    func scrollHistory(paneID: String, lines: Int, up: Bool, onScrollPosition: (@Sendable (Int) -> Void)?) {}
}

@MainActor
private final class FakeWorkitPauseClient: WorkitPauseClient {
    var requests: [WorkitPauseRequest] = []
    var onPause: (WorkitPauseRequest) async throws -> WorkitPausedJob = {
        WorkitPausedJob(id: $0.jobID, sessionID: $0.sessionID, revision: $0.expectedRevision + 1, stage: "paused")
    }
    func pause(_ request: WorkitPauseRequest) async throws -> WorkitPausedJob {
        requests.append(request)
        return try await onPause(request)
    }
}

@MainActor
@Suite struct PauseAndCloseTests {
    private func managed(_ store: SessionStore, state: SessionWorkflow.State = .waiting,
                         owner: String = "workit") throws -> BanyanSession {
        store.loadPersistedSessionsIfNeeded()
        try store.setWorkflow(id: "managed", workflow: .init(owner: owner, jobID: "job-a", revision: 3, state: state))
        return try #require(store.sessions.first { $0.id == "managed" })
    }

    private func project(_ store: SessionStore, revision: Int = 4, state: SessionWorkflow.State = .paused) throws {
        try store.setWorkflow(id: "managed", workflow: .init(owner: "workit", jobID: "job-a", revision: revision, state: state))
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
            store.confirmPendingClose()
            #expect(session.status == .closed)
            #expect(session.workflow?.state == state)
        } else {
            #expect(throws: (any Error).self) { try store.close(id: session.id) }
            #expect(session.status != .closed)
            #expect(store.pendingCloseMessage.contains("leaves the issue unfinished"))
            #expect(store.pendingCloseMessage.contains("stops future automatic continuation"))
            #expect(store.pendingCloseMessage.contains("may terminate the current coding agent"))
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

private struct WorkflowTestProcesses: ProcessTableProvider {
    func snapshot() -> ProcessTable { ProcessTable(rows: []) }
}
private struct WorkflowTestHistory: SessionHistoryBackend {
    var candidates: [AgentResumeCandidate] = []
    var supportsResume = true
    func load(maxPerProvider limit: Int) -> [ImportedAgentSession] { [] }
    func resumeCandidates(cwd: String, provider: CodingAgentProvider?, maxFilesScanned: Int) -> [AgentResumeCandidate] { candidates }
    func sourceID(fromImportedSessionID id: String, provider: CodingAgentProvider) -> String? { nil }
    func resumeCommand(provider: CodingAgentProvider, sourceID: String, cwd: String, prompt: String?) -> String? {
        supportsResume ? AgentSessionHistory.resumeCommand(provider: provider, sourceID: sourceID, cwd: cwd, prompt: prompt) : nil
    }
    func prepareTrimmedTranscript(provider: CodingAgentProvider, sourceID: String, cwd: String, transcriptURL: URL?) -> String? { nil }
    func transcriptPreview(from url: URL, provider: CodingAgentProvider, maxMessages: Int) -> String { "" }
}

extension SessionWorkflowStoreTests {
    @Test func hideKeepsWorkflowAndBackingWorkAndRestoresAfterRestart() throws {
        let fixture = try WorkflowStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let pause = FakeWorkitPauseClient()
        let store = fixture.makeStore(pauseClient: pause)
        defer { store.flushPendingSessionSaves() }
        store.loadPersistedSessionsIfNeeded()
        let session = try #require(store.sessions.first { $0.id == "managed" })
        let child = try #require(store.sessions.first { $0.id == "legacy" })
        child.parentSessionID = session.id
        let workflow = SessionWorkflow(owner: "workit", jobID: "job-a", revision: 2, state: .working)
        try store.setWorkflow(id: session.id, workflow: workflow)
        let before = (session.status, session.command, session.isSuspended, session.isFrozen)
        store.sidebarMode = .linear
        try store.hideAndKeepWorking(id: session.id)
        #expect(store.backgroundedSessionIDs.contains(child.id))
        #expect(store.visibleSessions.contains { $0.id == session.id })
        #expect(store.sidebarMode == .linear)
        #expect(store.collapsedParentIDs.contains(session.id))
        #expect(store.sessionWorkSummaries[session.id]?.descendants.count == 1)
        child.workflow = .init(owner: "workit", jobID: "child-job", revision: 1, state: .waiting)
        #expect(store.sessionWorkSummaries[session.id]?.groupLabel == "1 waiting")
        #expect(session.workflow == workflow)
        #expect(session.status == before.0 && session.command == before.1 && session.isSuspended == before.2 && session.isFrozen == before.3)
        #expect(pause.requests.isEmpty && fixture.backend.killed.isEmpty && fixture.backend.launched.isEmpty)
        let restored = fixture.makeStore()
        defer { restored.flushPendingSessionSaves() }
        restored.loadPersistedSessionsIfNeeded()
        #expect(restored.backgroundSessionRoots == ["managed"])
        #expect(restored.sidebarMode == .sessions)
        #expect(restored.visibleSessions.contains { $0.id == "managed" })
        #expect(restored.sessions.first { $0.id == "managed" }?.workflow == workflow)
        try store.revealBackgroundConversation(id: child.id)
        #expect(store.backgroundedSessionIDs.isEmpty)
        #expect(try store.backgroundJournal.load().isEmpty)
        #expect(session.workflow == workflow)
    }

    @Test func failedPresentationSaveCannotHideOrPauseWork() throws {
        let fixture = try WorkflowStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = fixture.makeStore()
        defer { store.flushPendingSessionSaves() }
        store.loadPersistedSessionsIfNeeded()
        try store.setWorkflow(id: "managed", workflow: .init(owner: "workit", jobID: "job-a", revision: 0, state: .working))
        try FileManager.default.createDirectory(at: store.backgroundJournal.file, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try store.hideAndKeepWorking(id: "managed") }
        #expect(store.backgroundSessionRoots.isEmpty)
        #expect(store.sessions.first { $0.id == "managed" }?.workflow?.state == .working)
        #expect(fixture.backend.killed.isEmpty)
    }

    @Test func attentionNavigationRevealsBackgroundWorkWithoutChangingWorkflow() throws {
        let fixture = try WorkflowStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = fixture.makeStore()
        defer { store.flushPendingSessionSaves() }
        store.loadPersistedSessionsIfNeeded()
        let session = try #require(store.sessions.first { $0.id == "managed" })
        try store.setWorkflow(id: session.id, workflow: .init(owner: "workit", jobID: "job-a", revision: 1, state: .working))
        try store.hideAndKeepWorking(id: session.id)
        let workflow = SessionWorkflow(owner: "workit", jobID: "job-a", revision: 2, state: .needsYou)
        try store.setWorkflow(id: session.id, workflow: workflow)
        session.status = .asking
        store.selection.selectedSessionID = "legacy"
        #expect(store.backgroundSessionRoots.contains(session.id))
        #expect(store.canSelectSessionNeedingAttention)
        store.selectNextSessionNeedingAttention()
        #expect(store.selection.selectedSessionID == session.id)
        #expect(store.backgroundSessionRoots.isEmpty)
        #expect(try store.backgroundJournal.load().isEmpty)
        #expect(session.workflow == workflow)
        #expect(fixture.backend.killed.isEmpty && fixture.backend.launched.isEmpty)
    }
}


@MainActor
@Suite struct CoordinationStoreTests {
    private func payload(_ action: String, id: String = "legacy", group: String = "group-a",
                         extra: [String: Any] = [:]) throws -> CoordinationControlPayload {
        var values: [String: Any] = ["action": action, "id": id, "groupID": group]
        values.merge(extra) { _, new in new }
        return try JSONDecoder().decode(CoordinationControlPayload.self, from: JSONSerialization.data(withJSONObject: values))
    }
    private func setup(_ fixture: WorkflowStoreFixture) async throws -> SessionStore {
        let store = fixture.makeStore()
        store.loadPersistedSessionsIfNeeded()
        store.selection.selectedSessionID = "legacy"
        store.sessions.first { $0.id == "managed" }?.parentSessionID = "legacy"
        store.sessions.first { $0.id == "busy" }?.parentSessionID = "legacy"
        _ = try await store.controlCoordination(payload("bind"))
        return store
    }
    @Test func bindingDoesNotOverwriteIssueWorkflowAndCannotStealAnotherGroup() async throws {
        let fixture = try WorkflowStoreFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try await setup(fixture); defer { store.flushPendingSessionSaves() }
        try store.setWorkflow(id: "legacy", workflow: .init(owner: "workit", jobID: "parent-job", revision: 8, state: .paused))
        _ = try await store.controlCoordination(payload("bind"))
        #expect(store.sessions.first { $0.id == "legacy" }?.workflow?.jobID == "parent-job")
        await #expect(throws: (any Error).self) { try await store.controlCoordination(payload("bind", group: "other")) }
        await #expect(throws: (any Error).self) {
            try await store.controlCoordination(payload("deliver", extra: ["revision": 1, "wakeID": "a", "text": "Continue"]))
        }
        #expect(fixture.backend.launched.isEmpty)
    }
    @Test func deliveredMessageCannotChangeIdentityOrContentAtSameRevision() async throws {
        let fixture = try WorkflowStoreFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try await setup(fixture); defer { store.flushPendingSessionSaves() }
        try store.coordinationJournal.bindings.save(.init(owner: "workit-coordinator", jobID: "group-a", revision: 1,
            state: .working, detail: "Update", wake: .init(id: "a", status: .delivered)), id: "legacy")
        _ = try await store.controlCoordination(payload("deliver", extra: ["revision": 1, "wakeID": "a", "text": "Update"]))
        for extra: [String: Any] in [["revision": 1, "wakeID": "b", "text": "Update"], ["revision": 1, "wakeID": "a", "text": "Changed"], ["revision": 0, "wakeID": "old", "text": "Update"]] {
            await #expect(throws: (any Error).self) { try await store.controlCoordination(payload("deliver", extra: extra)) }
        }
        _ = try await store.controlCoordination(payload("deliver", extra: ["revision": 1, "wakeID": "a", "text": "Update"]))
        #expect(fixture.backend.launched.isEmpty)
        #expect(fixture.backend.sent.isEmpty)
    }
    @Test func pendingCoordinatorReceiptSurvivesRestartAndNeverReplays() async throws {
        let fixture = try WorkflowStoreFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try await setup(fixture); defer { store.flushPendingSessionSaves() }
        try store.coordinationJournal.bindings.save(.init(owner: "workit-coordinator", jobID: "group-a", revision: 1,
            state: .working, detail: "Update", wake: .init(id: "a", status: .pending)), id: "legacy")
        let restored = fixture.makeStore(); restored.loadPersistedSessionsIfNeeded()
        defer { restored.flushPendingSessionSaves() }
        await #expect(throws: (any Error).self) {
            try await restored.controlCoordination(payload("deliver", extra: ["revision": 1, "wakeID": "a", "text": "Update"]))
        }
        #expect(fixture.backend.launched.isEmpty)
        #expect(try restored.coordinationJournal.bindings.load(id: "legacy")?.wake?.status == .pending)
    }
    @Test func retirementIsScopedQuietRevisionGuardedAndRetainsHistory() async throws {
        let fixture = try WorkflowStoreFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try await setup(fixture); defer { store.flushPendingSessionSaves() }
        try store.setWorkflow(id: "managed", workflow: .init(owner: "workit", jobID: "child-job", revision: 4, state: .verified))
        try store.setWorkflow(id: "busy", workflow: .init(owner: "workit", jobID: "busy-job", revision: 4, state: .verified))
        let base: [String: Any] = ["parent": "legacy", "jobID": "child-job", "revision": 4]
        for extra: [String: Any] in [["parent": "other", "jobID": "child-job", "revision": 4], ["parent": "legacy", "jobID": "wrong", "revision": 4], ["parent": "legacy", "jobID": "child-job", "revision": 3]] {
            await #expect(throws: (any Error).self) { try await store.controlCoordination(payload("retire", id: "managed", extra: extra)) }
        }
        await #expect(throws: (any Error).self) {
            try await store.controlCoordination(payload("retire", id: "busy", extra: ["parent": "legacy", "jobID": "busy-job", "revision": 4]))
        }
        store.selection.selectedSessionID = "managed"
        await #expect(throws: (any Error).self) { try await store.controlCoordination(payload("retire", id: "managed", extra: base)) }
        store.selection.selectedSessionID = "legacy"
        _ = try await store.controlCoordination(payload("retire", id: "managed", extra: base))
        #expect(store.sessions.first { $0.id == "managed" }?.status == .closed)
        #expect(store.sessions.first { $0.id == "busy" }?.status == .executing)
        #expect(store.sessions.first { $0.id == "legacy" }?.status != .closed)
        _ = try await store.controlCoordination(payload("retire", id: "managed", extra: base))
    }
    @Test func directInputPersistsAndInvalidatesEarlierRetirement() async throws {
        let fixture = try WorkflowStoreFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try await setup(fixture); defer { store.flushPendingSessionSaves() }
        let child = try #require(store.sessions.first { $0.id == "managed" })
        try store.setWorkflow(id: child.id, workflow: .init(owner: "workit", jobID: "child-job", revision: 2, state: .verified))
        child.onUserSubmittedInput?("Keep the existing UI")
        let values = try store.coordinationJournal.interventions(id: child.id)
        #expect(values.count == 1)
        #expect(values.first?.text == "Keep the existing UI")
        await #expect(throws: (any Error).self) {
            try await store.controlCoordination(payload("retire", id: child.id, extra: ["parent": "legacy", "jobID": "child-job", "revision": 2]))
        }
        let restored = fixture.makeStore()
        #expect(try restored.coordinationJournal.interventions(id: child.id) == values)
    }
    @Test func replacedPaneDuringRetirementIsNeverKilled() async throws {
        let fixture = try WorkflowStoreFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try await setup(fixture); defer { store.flushPendingSessionSaves() }
        try store.setWorkflow(id: "managed", workflow: .init(owner: "workit", jobID: "child-job", revision: 2, state: .verified))
        fixture.backend.replacementAfterFirstInspection = TmuxPaneSnapshot(paneID: "%replacement", rootPID: 333,
            currentCommand: "codex", currentPath: fixture.root.path, isDead: false, isInMode: false)
        await #expect(throws: (any Error).self) {
            try await store.controlCoordination(payload("retire", id: "managed", extra: ["parent": "legacy", "jobID": "child-job", "revision": 2]))
        }
        #expect(fixture.backend.killed.isEmpty)
    }
}

extension CoordinationStoreTests {
    @Test func helperRetirementRequiresOriginalWorkerRunAndVerifiedRevision() async throws {
        let fixture = try WorkflowStoreFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try await setup(fixture); defer { store.flushPendingSessionSaves() }
        try store.setWorkflow(id: "managed", workflow: .init(owner: "workit", jobID: "child-job", revision: 4, state: .verified))
        let helper = try #require(store.sessions.first { $0.id == "busy" }); helper.status = .completed
        let binding: [String: Any] = ["parent": "legacy", "worker": "managed", "runID": "review", "jobID": "child-job", "revision": 4]
        await #expect(throws: (any Error).self) { try await store.controlCoordination(payload("retire-helper", id: helper.id, extra: binding)) }
        _ = try await store.controlCoordination(payload("helper", id: helper.id, extra: binding))
        await #expect(throws: (any Error).self) {
            try await store.controlCoordination(payload("retire-helper", id: helper.id, extra: binding.merging(["runID": "other"]) { _, new in new }))
        }
        helper.onUserSubmittedInput?("Inspect this verifier before closing")
        await #expect(throws: (any Error).self) { try await store.controlCoordination(payload("retire-helper", id: helper.id, extra: binding)) }
        let intervention = try #require(store.coordinationJournal.interventions(id: helper.id).last)
        _ = try await store.controlCoordination(payload("retire-helper", id: helper.id, extra: binding.merging(["interventionID": intervention.id]) { _, new in new }))
        #expect(helper.status == .closed)
        #expect(store.sessions.first { $0.id == "managed" }?.status != .closed)
        _ = try await store.controlCoordination(payload("retire-helper", id: helper.id, extra: binding))
    }
}
