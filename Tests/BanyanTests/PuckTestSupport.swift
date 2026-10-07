import AppKit
import BanyanCore
import Foundation
@testable import Banyan

/// An in-memory `puckd`: serves the sessions a test puts in it and records
/// what Banyan asked of it.
final class FakePuckDaemon: PuckDaemonService, @unchecked Sendable {
    struct Creation: Equatable {
        let id: String
        let provider: String
        let account: String?
        let model: String?
        let workspace: String
    }

    struct Turn: Equatable {
        let id: String
        let prompt: String
    }

    private let lock = NSLock()
    private var summaries: [String: PuckSessionSummary] = [:]
    private var transcripts: [String: [PuckSessionEvent]] = [:]
    private var followers: [String: AsyncThrowingStream<PuckSessionUpdate, Error>.Continuation] = [:]
    private var recordedCreations: [Creation] = []
    private var recordedTurns: [Turn] = []
    private var recordedDecisions: [String] = []
    private var reachable = true
    private var turnGate: DispatchSemaphore?
    func holdTurns() -> DispatchSemaphore {
        let gate = DispatchSemaphore(value: 0)
        locked { turnGate = gate }
        return gate
    }
    private var getGate: DispatchSemaphore?
    private var startedGets = 0
    var getsStarted: Int { locked { startedGets } }
    func holdGets() -> DispatchSemaphore {
        let gate = DispatchSemaphore(value: 0)
        locked { getGate = gate }
        return gate
    }
    private var createGate: DispatchSemaphore?
    private var listGate: DispatchSemaphore?
    private var completedLists = 0

    var creations: [Creation] { locked { recordedCreations } }
    var turns: [Turn] { locked { recordedTurns } }
    var decisions: [String] { locked { recordedDecisions } }

    var isReachable: Bool {
        get { locked { reachable } }
        set { locked { reachable = newValue } }
    }

    func isFollowed(_ id: String) -> Bool {
        locked { followers[id] != nil }
    }

    var listsReturned: Int { locked { completedLists } }

    /// Holds each `create` after the daemon has the session and before the
    /// call returns, until the returned semaphore is signalled.
    func holdCreates() -> DispatchSemaphore {
        let gate = DispatchSemaphore(value: 0)
        locked { createGate = gate }
        return gate
    }

    /// Holds each `list` after it has read the sessions and before it
    /// returns them, so the answer can go stale while it waits.
    func holdLists() -> DispatchSemaphore {
        let gate = DispatchSemaphore(value: 0)
        locked { listGate = gate }
        return gate
    }

    func put(_ summary: PuckSessionSummary, transcript: [PuckSessionEvent] = []) {
        locked {
            summaries[summary.id] = summary
            transcripts[summary.id] = transcript
        }
    }

    func forget(_ id: String) {
        _ = locked { summaries.removeValue(forKey: id) }
    }

    func push(_ update: PuckSessionUpdate, to id: String) {
        locked { followers[id] }?.yield(update)
    }

    /// Ends a follower's stream the way a daemon restart does.
    func dropFollower(_ id: String, error: Error? = nil) {
        let follower = locked { followers.removeValue(forKey: id) }
        follower?.finish(throwing: error)
    }

    // MARK: PuckDaemonService

    func list() throws -> [PuckSessionSummary] {
        let (listed, gate) = try locked {
            try checkReachable()
            return (summaries.values.sorted { $0.id < $1.id }, listGate)
        }
        gate?.wait()
        locked { completedLists += 1 }
        return listed
    }

    func get(_ id: String) throws -> PuckSessionSummary {
        let gate = locked { startedGets += 1; return getGate }
        gate?.wait()
        return try locked {
            try checkReachable()
            guard let summary = summaries[id] else { throw PuckDaemonError.rejected("unknown session \(id)") }
            return summary
        }
    }

    func create(id: String, provider: String, account: String?, model: String?, workspace: String) throws -> PuckSessionSummary {
        let (summary, gate) = try locked {
            try checkReachable()
            recordedCreations.append(Creation(id: id, provider: provider, account: account, model: model, workspace: workspace))
            // Like puckd, fill in the defaults the request left out.
            let summary = puckSummary(
                id: id,
                provider: provider,
                account: account ?? "default",
                model: model ?? "\(provider)-default",
                cwd: workspace
            )
            summaries[id] = summary
            return (summary, createGate)
        }
        gate?.wait()
        return summary
    }

    func turn(_ id: String, prompt: String) throws {
        let gate = try locked {
            try checkReachable()
            guard let summary = summaries[id] else { throw PuckDaemonError.rejected("unknown session \(id)") }
            recordedTurns.append(Turn(id: id, prompt: prompt))
            summaries[id] = summary.with(position: "running", historyItems: summary.historyItems + 1)
            return turnGate
        }
        gate?.wait()
    }

    func decide(_ id: String, callID: String, decision: String) throws {
        try locked {
            try checkReachable()
            guard let summary = summaries[id] else { throw PuckDaemonError.rejected("unknown session \(id)") }
            recordedDecisions.append(decision)
            summaries[id] = summary.with(position: "running", pendingApproval: .some(nil))
        }
    }

    func answer(_ id: String, callID: String, selections: [PuckQuestionSelection]) throws {
        try locked {
            try checkReachable()
            guard let summary = summaries[id] else { throw PuckDaemonError.rejected("unknown session \(id)") }
            summaries[id] = summary.with(position: "running", pendingQuestion: .some(nil))
        }
    }

    func follow(_ id: String) -> AsyncThrowingStream<PuckSessionUpdate, Error> {
        AsyncThrowingStream { continuation in
            let attached: (PuckSessionSummary, [PuckSessionEvent])? = locked {
                guard reachable, let summary = summaries[id] else { return nil }
                followers[id] = continuation
                return (summary, transcripts[id] ?? [])
            }
            guard let attached else {
                continuation.finish(throwing: PuckDaemonError.unavailable("fake puckd is down"))
                return
            }
            continuation.onTermination = { [weak self] _ in
                self?.locked { _ = self?.followers.removeValue(forKey: id) }
            }
            continuation.yield(.attached(attached.0, attached.1))
        }
    }

    func plan(_ id: String) throws -> String? { nil }
    func reject(_ id: String, callID: String, reason: String) throws {}

    private var watchers: [FakePuckObservation] = []

    func watch() -> any PuckDaemonObservation {
        let observer = FakePuckObservation()
        locked { watchers.append(observer) }
        do { observer.continuation.yield(.snapshot(try list())) }
        catch { observer.continuation.finish(throwing: error) }
        return observer
    }

    func publishWatch(_ update: PuckDaemonWatchUpdate) {
        for observer in locked({ watchers }) { observer.continuation.yield(update) }
    }

    func dropWatchers() {
        for observer in locked({ watchers }) { observer.continuation.finish() }
    }

    var watchCount: Int { locked { watchers.count } }

    private func checkReachable() throws {
        guard reachable else { throw PuckDaemonError.unavailable("fake puckd is down") }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

final class FakePuckObservation: PuckDaemonObservation, @unchecked Sendable {
    let updates: AsyncThrowingStream<PuckDaemonWatchUpdate, Error>
    let continuation: AsyncThrowingStream<PuckDaemonWatchUpdate, Error>.Continuation
    private let lock = NSLock()
    private var reports: [Bool] = []
    var presenceReports: [Bool] { lock.withLock { reports } }

    init() {
        let stream = AsyncThrowingStream<PuckDaemonWatchUpdate, Error>.makeStream()
        updates = stream.stream
        continuation = stream.continuation
    }

    func reportPresence(active: Bool) { lock.withLock { reports.append(active) } }
    func cancel() { continuation.finish() }
}

func puckSummary(
    id: String = "0f6c3a52-8c1e-4d7b-9a55-3b1f1d2e4c10",
    provider: String = "codex",
    account: String = "default",
    model: String = "gpt-5.5",
    cwd: String,
    position: String = "idle",
    historyItems: Int = 0,
    pendingApproval: PuckPendingApproval? = nil,
    pendingQuestion: PuckPendingQuestion? = nil
) -> PuckSessionSummary {
    PuckSessionSummary(
        id: id,
        provider: provider,
        account: account,
        workspace: cwd,
        cwd: cwd,
        model: model,
        position: position,
        historyItems: historyItems,
        pendingApproval: pendingApproval,
        pendingQuestion: pendingQuestion
    )
}

extension PuckSessionSummary {
    func with(
        position: String? = nil,
        historyItems: Int? = nil,
        pendingApproval: PuckPendingApproval?? = nil,
        pendingQuestion: PuckPendingQuestion?? = nil
    ) -> PuckSessionSummary {
        PuckSessionSummary(
            id: id,
            provider: provider,
            account: account,
            workspace: workspace,
            cwd: cwd,
            model: model,
            position: position ?? self.position,
            historyItems: historyItems ?? self.historyItems,
            pendingApproval: pendingApproval ?? self.pendingApproval,
            pendingQuestion: pendingQuestion ?? self.pendingQuestion
        )
    }
}

/// A store over a private database and home, backed by the given daemon.
/// Like the other store fixtures it leaves its temporary directory behind: a
/// store writes on a background queue, and a write racing a delete only logs
/// noise.
@MainActor
struct PuckStoreFixture {
    let root: URL
    let home: URL
    let project: URL
    let persistence: SessionPersistence
    let daemon: any PuckDaemonService

    init(daemon: any PuckDaemonService) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("banyan-puck-\(UUID().uuidString)")
        home = root.appendingPathComponent("home")
        project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        persistence = SessionPersistence(
            databaseURL: root.appendingPathComponent("state.sqlite"),
            legacyJSONURL: root.appendingPathComponent("sessions.json")
        )
        self.daemon = daemon
    }

    func makeStore(codexService: (any CodexThreadService)? = nil,
                   historyBackend: (any SessionHistoryBackend)? = nil,
                   tmuxBackend: TmuxBackend? = nil,
                   sessionBackend: (any TmuxClientBackend)? = nil,
                   processTable: (any ProcessTableProvider)? = nil,
                   freezePreferences: UserDefaults = .standard,
                   makeControlServer: @escaping (SessionStore, HostRuntimeContext) -> ControlServer = {
                       ControlServer(store: $0, host: $1)
                   }) -> SessionStore {
        // The store reads `NSApp` for its background-refresh budget, which is nil
        // in a test process until the shared application exists.
        _ = NSApplication.shared
        let tmux = tmuxBackend ?? banyanTestTmuxBackend
        return SessionStore(
            persistence: persistence,
            tmuxBackend: tmux,
            sessionBackend: sessionBackend ?? tmux,
            processTable: processTable ?? EmptyPuckTestProcessTable(),
            historyBackend: historyBackend ?? EmptyPuckTestHistoryBackend(),
            detector: AgentStateDetector(rules: []),
            host: HostRuntimeContext(
                environment: [
                    "HOME": home.path,
                    "BANYAN_FIXTURE_DATA_HOME": root.appendingPathComponent("app-data").path,
                    "PATH": "/usr/bin:/bin",
                    "SHELL": "/bin/zsh"
                ],
                homeDirectory: home,
                currentDirectory: project.path
            ),
            telemetry: banyanTestTelemetry,
            attentionNotifier: AttentionNotifier(),
            puckDaemon: daemon,
            codexService: codexService,
            freezePreferences: freezePreferences,
            makeControlServer: makeControlServer
        )
    }

}

/// Waits for state an async hop sets. Bounded, like the app's own waits: a
/// broken path must fail, not hang.
@MainActor
func waitForPuckState(
    timeout: Duration = .seconds(5),
    until condition: () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now >= deadline {
            throw PuckTestTimeout()
        }
        try await Task.sleep(for: .milliseconds(20))
    }
}

struct PuckTestTimeout: Error {}

private struct EmptyPuckTestProcessTable: ProcessTableProvider {
    func snapshot() -> ProcessTable {
        ProcessTable(rows: [])
    }
}

private struct EmptyPuckTestHistoryBackend: SessionHistoryBackend {
    func load(maxPerProvider limit: Int) -> [ImportedAgentSession] { [] }

    func resumeCandidates(
        cwd: String,
        provider: CodingAgentProvider?,
        maxFilesScanned: Int
    ) -> [AgentResumeCandidate] {
        []
    }

    func sourceID(fromImportedSessionID id: String, provider: CodingAgentProvider) -> String? { nil }

    func resumeCommand(
        provider: CodingAgentProvider,
        sourceID: String,
        cwd: String,
        prompt: String?
    ) -> String? {
        nil
    }

    func prepareTrimmedTranscript(
        provider: CodingAgentProvider,
        sourceID: String,
        cwd: String,
        transcriptURL: URL?
    ) -> String? {
        nil
    }

    func transcriptPreview(from url: URL, provider: CodingAgentProvider, maxMessages: Int) -> String { "" }
}
