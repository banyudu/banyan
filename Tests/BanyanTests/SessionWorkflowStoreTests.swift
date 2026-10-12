import AppKit
import BanyanCore
import Foundation
import Testing
@testable import Banyan

@MainActor
@Suite struct SessionWorkflowStoreTests {
    @Test func restoreSeparatesProcessCompletionFromIssueCompletionAndProtectsClose() throws {
        let fixture = try WorkflowStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = fixture.makeStore()
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
    func makeStore(history: WorkflowTestHistory = WorkflowTestHistory()) -> SessionStore {
        _ = NSApplication.shared
        return SessionStore(persistence: persistence, tmuxBackend: backend, sessionBackend: backend,
            processTable: WorkflowTestProcesses(), historyBackend: history,
            detector: AgentStateDetector(rules: []),
            host: HostRuntimeContext(environment: ["BANYAN_FIXTURE_DATA_HOME": root.path, "PATH": "/usr/bin:/bin", "SHELL": "/bin/zsh"],
                homeDirectory: root, currentDirectory: root.path),
            telemetry: banyanTestTelemetry, attentionNotifier: AttentionNotifier())
    }
}

private final class WorkflowTestBackend: TmuxSessionStoreBackend, TmuxClientBackend, @unchecked Sendable {
    var sent: [String] = []
    var launched: [String] = []
    var replacementAfterFirstInspection: TmuxPaneSnapshot?
    private var inspections = 0
    var executableURL: URL { URL(fileURLWithPath: "/usr/bin/false") }
    func attachArguments(for name: String) -> [String] { [] }
    func hasSession(named name: String) -> Bool { false }
    func agentAdmissionPane(named name: String) -> AgentAdmissionPaneInspection {
        inspections += 1
        if inspections > 1, let replacementAfterFirstInspection { return .present(replacementAfterFirstInspection) }
        return .absent
    }
    func primaryPaneSnapshot(named name: String) -> TmuxPaneSnapshot? { nil }
    func captureVisibleText(paneID: String, lineLimit: Int) -> String { "" }
    func captureCurrentVisibleText(paneID: String) -> String { "" }
    func listBanyanSessions() -> [String] { [] }
    func ensureSession(named name: String, cwd: String, command: String, banyanSessionID: String?) throws { launched.append(command) }
    func killSession(named name: String) {}
    func sendKeys(paneID: String, keys: [TmuxKey]) throws { sent.append("keys") }
    func sendLiteral(paneID: String, text: String) throws { sent.append(text) }
    func configureTerminalTheme(style: String, for sessionName: String?) {}
    func refreshClients(attachedTo name: String) {}
    func scrollHistory(paneID: String, lines: Int, up: Bool, onScrollPosition: (@Sendable (Int) -> Void)?) {}
}

private struct WorkflowTestProcesses: ProcessTableProvider {
    func snapshot() -> ProcessTable { ProcessTable(rows: []) }
}
private struct WorkflowTestHistory: SessionHistoryBackend {
    var candidates: [AgentResumeCandidate] = []
    func load(maxPerProvider limit: Int) -> [ImportedAgentSession] { [] }
    func resumeCandidates(cwd: String, provider: CodingAgentProvider?, maxFilesScanned: Int) -> [AgentResumeCandidate] { candidates }
    func sourceID(fromImportedSessionID id: String, provider: CodingAgentProvider) -> String? { nil }
    func resumeCommand(provider: CodingAgentProvider, sourceID: String, cwd: String, prompt: String?) -> String? {
        AgentSessionHistory.resumeCommand(provider: provider, sourceID: sourceID, cwd: cwd, prompt: prompt)
    }
    func prepareTrimmedTranscript(provider: CodingAgentProvider, sourceID: String, cwd: String, transcriptURL: URL?) -> String? { nil }
    func transcriptPreview(from url: URL, provider: CodingAgentProvider, maxMessages: Int) -> String { "" }
}
