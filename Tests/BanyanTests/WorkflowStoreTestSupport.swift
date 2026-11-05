import AppKit
import Combine
import BanyanCore
import Foundation
import Network
import Testing
@testable import Banyan


@MainActor
struct WorkflowStoreFixture {
    let root: URL
    let persistence: SessionPersistence
    let backend = WorkflowTestBackend()
    init(sessionIDs: [String] = ["managed", "legacy", "busy"]) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("banyan_workflow_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        // This fixture exercises sidebar presentation, not a live tracker or
        // the developer's login shell. Intercept both before building a store.
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let shell = bin.appendingPathComponent("fixture-shell")
        let linear = bin.appendingPathComponent("linear")
        try "#!/bin/sh\nprintf '\\n__BANYAN_SHELL_ENV_START__\\nPATH=/usr/bin:/bin\\0'\n".write(to: shell, atomically: true, encoding: .utf8)
        try "#!/bin/sh\nprintf fixture > \"$HOME/linear-invoked\"\nexit 1\n".write(to: linear, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: linear.path)
        persistence = SessionPersistence(databaseURL: root.appendingPathComponent("state.sqlite"),
            legacyJSONURL: root.appendingPathComponent("sessions.json"))
        let now = Date()
        persistence.save(sessionIDs.map { id in
            SessionSnapshot(id: id, tmuxSessionName: "banyan-\(id)", title: id, reportedTitle: nil,
                cwd: root.path, command: "codex 'Original implementation prompt'", status: id == "busy" ? .executing : .completed,
                tone: .neutral, createdAt: now, updatedAt: now)
        })
    }
    func makeStore(history: WorkflowTestHistory = WorkflowTestHistory(),
                   pauseClient: (any WorkitPauseClient)? = nil,
                   projectionTimeout: Duration = .milliseconds(50),
                   processes: WorkflowTestProcesses = WorkflowTestProcesses(),
                   codexService: (any CodexThreadService)? = nil) -> SessionStore {
        _ = NSApplication.shared
        return SessionStore(persistence: persistence, tmuxBackend: backend, sessionBackend: backend,
            processTable: processes, historyBackend: history,
            detector: AgentStateDetector(rules: []),
            host: HostRuntimeContext(environment: ["BANYAN_FIXTURE_DATA_HOME": root.path, "HOME": root.path,
                "PATH": root.appendingPathComponent("bin").path + ":/usr/bin:/bin", "SHELL": root.appendingPathComponent("bin/fixture-shell").path],
                homeDirectory: root, currentDirectory: root.path),
            telemetry: banyanTestTelemetry, attentionNotifier: AttentionNotifier(), codexService: codexService,
            workitPauseClient: pauseClient, pauseCloseProjectionTimeout: projectionTimeout)
    }
}

final class WorkflowTestBackend: TmuxSessionStoreBackend, TmuxClientBackend, @unchecked Sendable {
    var sent: [String] = []
    var launched: [String] = []
    var killed: [String] = []
    var replacementAfterFirstInspection: TmuxPaneSnapshot?
    var observedPane: TmuxPaneSnapshot?
    var readablePane: TmuxPaneSnapshot?
    var visibleText = ""
    private var inspections = 0
    var executableURL: URL { URL(fileURLWithPath: "/usr/bin/false") }
    func attachArguments(for name: String) -> [String] { [] }
    func hasSession(named name: String) -> Bool { false }
    func agentAdmissionPane(named name: String) -> AgentAdmissionPaneInspection {
        inspections += 1
        if inspections > 1, let replacementAfterFirstInspection { return .present(replacementAfterFirstInspection) }
        if let observedPane { return .present(observedPane) }
        if let readablePane { return .present(readablePane) }
        return .absent
    }
    func primaryPaneSnapshot(named name: String) -> TmuxPaneSnapshot? { readablePane }
    func captureVisibleText(paneID: String, lineLimit: Int) -> String { visibleText }
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
final class FakeWorkitPauseClient: WorkitPauseClient {
    var requests: [WorkitPauseRequest] = []
    var onPause: (WorkitPauseRequest) async throws -> WorkitPausedJob = {
        WorkitPausedJob(id: $0.jobID, sessionID: $0.sessionID, revision: $0.expectedRevision + 1, stage: "paused")
    }
    func pause(_ request: WorkitPauseRequest) async throws -> WorkitPausedJob {
        requests.append(request)
        return try await onPause(request)
    }
}

struct WorkflowTestProcesses: ProcessTableProvider {
    var rows: [ProcessInfoRow] = []
    func snapshot() -> ProcessTable { ProcessTable(rows: rows) }
}

@MainActor
final class WorkflowObserverService: CodexThreadService {
    var requests: [String] = []
    func events() async -> AsyncStream<CodexAppServerEvent> { AsyncStream { $0.finish() } }
    func setServerRequestHandler(_ handler: CodexAppServerClient.RequestHandler?) async {}
    func request(_ method: String, params: CodexJSONValue) async throws -> CodexJSONValue {
        requests.append(method)
        throw WorkflowError.refused("observer fixture does not deliver native requests")
    }
}
struct WorkflowTestHistory: SessionHistoryBackend {
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
