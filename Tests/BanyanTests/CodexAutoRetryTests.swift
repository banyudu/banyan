import AppKit
import Foundation
import Testing
@testable import Banyan
@testable import BanyanCore

@MainActor
private final class RetryClock {
    var waits: [(UUID, CheckedContinuation<Void, any Error>)] = []
    func sleep() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                waits.append((id, continuation))
            }
        } onCancel: { Task { @MainActor in self.cancel(id) } }
    }
    private func cancel(_ id: UUID) {
        if let index = waits.firstIndex(where: { $0.0 == id }) { waits.remove(at: index).1.resume(throwing: CancellationError()) }
    }
    func advance() { if !waits.isEmpty { waits.removeFirst().1.resume() } }
}

@MainActor
private final class RetryServer: CodexThreadService {
    let stream: AsyncStream<CodexAppServerEvent>
    let continuation: AsyncStream<CodexAppServerEvent>.Continuation
    var turns: [CodexJSONValue] = []
    let home: String
    var currentTurnID: String { "turn-\(turns.count)" }
    init(home: String) { self.home = home; (stream, continuation) = AsyncStream.makeStream() }
    func events() async -> AsyncStream<CodexAppServerEvent> { stream }
    func setServerRequestHandler(_ handler: CodexAppServerClient.RequestHandler?) async {}
    func storageHome() async -> String? { home }
    func disconnectForHandoff() async throws {}
    func request(_ method: String, params: CodexJSONValue) async throws -> CodexJSONValue {
        if method == "turn/start" {
            turns.append(params)
            let turn: CodexJSONValue = .object(["id": .string(currentTurnID), "status": .string("inProgress")])
            emit("turn/started", fields: ["turn": turn])
            return .object(["turn": turn])
        }
        if method == "thread/unsubscribe" { return .object(["status": .string("unsubscribed")]) }
        return .object(["thread": .object(["id": .string("retry-thread"),
            "status": .object(["type": .string("idle")]), "turns": .array([])])])
    }
    func emit(_ method: String, fields: [String: CodexJSONValue], turnID: String? = nil) {
        continuation.yield(.notification(method: method, params: .object(fields.merging([
            "threadId": .string("retry-thread"), "turnId": .string(turnID ?? currentTurnID)
        ]) { _, new in new })))
    }
    func fail(code: String = "serverOverloaded", willRetry: Bool = false, turnID: String? = nil) {
        let error: CodexJSONValue = .object(["message": .string("Selected model is at capacity. Please try a different model."), "codexErrorInfo": .string(code)])
        emit("error", fields: ["error": error, "willRetry": .bool(willRetry)], turnID: turnID)
        emit("turn/completed", fields: ["turn": .object(["id": .string(turnID ?? currentTurnID),
            "status": .string("failed"), "error": error])], turnID: turnID)
    }
}

private final class RetryTerminalBackend: TmuxSessionStoreBackend, TmuxClientBackend, @unchecked Sendable {
    let executableURL = URL(fileURLWithPath: "/usr/bin/false")
    let lock = NSLock()
    var live: Set<String> = []
    var screen = "Read files\n■ Selected model is at capacity. Please try a different model.\n\n› Ask Codex to do anything\nGPT · Context 15% used\n? for shortcuts"
    var rootPID = Int(ProcessInfo.processInfo.processIdentifier)
    var commandName = "codex"
    var isInMode = false
    var recorded: [String] = []
    var writes: [String] { lock.withLock { recorded } }
    func hasSession(named: String) -> Bool { lock.withLock { live.contains(named) } }
    func ensureSession(named: String, cwd: String, command: String, banyanSessionID: String?) throws { _ = lock.withLock { live.insert(named) } }
    func killSession(named: String) { _ = lock.withLock { live.remove(named) } }
    func listBanyanSessions() -> [String] { [] }
    func primaryPaneSnapshot(named: String) -> TmuxPaneSnapshot? {
        lock.withLock {
            guard live.contains(named) else { return nil }
            return .init(paneID: "%1", rootPID: rootPID, currentCommand: commandName, currentPath: "/tmp", isDead: false, isInMode: isInMode)
        }
    }
    func captureVisibleText(paneID: String, lineLimit: Int) -> String { lock.withLock { screen } }
    func captureCurrentVisibleText(paneID: String) -> String { captureVisibleText(paneID: paneID, lineLimit: 60) }
    func sendLiteral(paneID: String, text: String) throws { lock.withLock { recorded.append(text) } }
    func sendKeys(paneID: String, keys: [TmuxKey]) throws { lock.withLock { recorded.append(keys.map(\.rawValue).joined(separator: ",")) } }
    func attachArguments(for name: String) -> [String] { [] }
    func configureTerminalTheme(style: String, for sessionName: String?) {}
    func refreshClients(attachedTo name: String) {}
    func scrollHistory(paneID: String, lines: Int, up: Bool, onScrollPosition: (@Sendable (Int) -> Void)?) {}
    func freezeTicket(named name: String) -> AgentFreezeTicket? { nil }
    func writeFreezeTicket(_ ticket: AgentFreezeTicket?, named name: String) throws {}
}

private struct RetryProcessTable: ProcessTableProvider {
    let backend: RetryTerminalBackend
    func snapshot() -> ProcessTable {
        backend.lock.withLock {
            .init(rows: [.init(pid: backend.rootPID, parentPID: 1, state: "S", elapsed: 10,
                commandName: backend.commandName, arguments: backend.commandName)])
        }
    }
}

@Suite(.serialized) @MainActor
struct CodexAutoRetryTests {
    @Test func nativeRetriesSameThreadAndModelWithoutReplayingTheTask() async throws {
        let (fixture, store, session, server, clock) = try await nativeFixture()
        _ = fixture
        let binding = session.state.binding
        server.fail()
        try await waitForPuckState { clock.waits.count == 1 }
        #expect(session.codexRetryStatus?.attempt == 1)
        #expect(server.turns.count == 1)
        clock.advance()
        try await waitForPuckState { server.turns.count == 2 && session.codexRetryStatus == nil }
        #expect(server.turns[1].objectValue?["threadId"] == .string("retry-thread"))
        #expect(server.turns[1].objectValue?["input"]?.arrayValue.first?.objectValue?["text"] == .string(CodexRetryPolicy.continuation))
        #expect(session.state.binding == binding)
        #expect(store.sessions.contains { $0 === session })
        server.fail()
        try await waitForPuckState { session.codexRetryStatus?.attempt == 2 }
        session.codexAutoRetry.cancel()
    }

    @Test func nativeOwnRetriesPermanentFailuresAndOldCompletionsAreLeftAlone() async throws {
        let (_, store, session, server, clock) = try await nativeFixture()
        server.emit("error", fields: ["willRetry": .bool(true), "error": .object(["message": .string("Capacity")])])
        try await waitForPuckState { session.codexOwnsRetryTurnID == server.currentTurnID }
        #expect(clock.waits.isEmpty)
        server.fail(willRetry: false)
        try await waitForPuckState { clock.waits.count == 1 }
        session.draft = "A new task"
        #expect(session.codexRetryStatus == nil)
        await session.sendDraft()
        let current = server.currentTurnID
        server.fail(turnID: "turn-1")
        try await waitForPuckState { session.state.activeTurnID == current }
        #expect(session.codexRetryStatus == nil)
        server.fail(code: "usageLimitExceeded")
        try await waitForPuckState { session.state.activeTurnID == nil }
        #expect(session.codexRetryStatus == nil)
        #expect(server.turns.count == 2)
        #expect(store.sessions.contains { $0 === session })
    }

    @Test(arguments: ["draft", "interrupt", "close", "disable", "new-turn"])
    func nativeInteractionCancelsPendingRetry(action: String) async throws {
        let (_, store, session, server, clock) = try await nativeFixture()
        server.fail()
        try await waitForPuckState { clock.waits.count == 1 }
        switch action {
        case "draft": session.draft = "Unsent draft"
        case "interrupt": await session.interrupt()
        case "close": session.closeBackingSession()
        case "disable": store.autoRetryCodexFailures = false
        default: server.emit("turn/started", fields: ["turn": .object(["id": .string("external-turn"), "status": .string("inProgress")])], turnID: "external-turn")
        }
        try await waitForPuckState { session.codexRetryStatus == nil && clock.waits.isEmpty }
        #expect(server.turns.count == 1)
    }

    @Test func terminalCapacityFailureRecoversWithoutLoadingATerminalView() async throws {
        let (_, store, session, backend, clock) = try await terminalFixture()
        let observation = try terminalObservation(store, session)
        #expect(observation.codexRetryCandidate != nil)
        _ = store.applySupervisorResults([observation])
        try await waitForPuckState { clock.waits.count == 1 }
        _ = store.applySupervisorResults([observation]) // A quiet redraw cannot queue another attempt.
        clock.advance()
        try await waitForPuckState { backend.writes.count == 2 }
        #expect(backend.writes == [CodexRetryPolicy.continuation, "Enter"])
        #expect(session.loadedTerminalView == nil)
        #expect(session.codexAutoRetry.attempts == 1)
        _ = store.applySupervisorResults([observation])
        #expect(session.codexRetryStatus == nil)
    }

    @Test(arguments: ["composer", "active", "stale", "process", "shell", "copy-mode", "close", "input", "disable"])
    func terminalRevalidatesBeforeEverySubmission(change: String) async throws {
        let (_, store, session, backend, clock) = try await terminalFixture()
        _ = store.applySupervisorResults([try terminalObservation(store, session)])
        try await waitForPuckState { clock.waits.count == 1 }
        switch change {
        case "composer": backend.lock.withLock { backend.screen = backend.screen.replacingOccurrences(of: "Ask Codex to do anything", with: "Unsent draft") }
        case "active": backend.lock.withLock { backend.screen += "\nEsc to interrupt" }
        case "stale": backend.lock.withLock { backend.screen = backend.screen.replacingOccurrences(of: "\n\n›", with: "\nDone\n\n›") }
        case "process": backend.lock.withLock { backend.rootPID = 2_000_000 }
        case "shell": backend.lock.withLock { backend.commandName = "zsh" }
        case "copy-mode": backend.lock.withLock { backend.isInMode = true }
        case "close": session.closeBackingSession()
        case "input": store.noteCodexRetryInteraction(session)
        default: store.autoRetryCodexFailures = false
        }
        clock.advance()
        try await waitForPuckState { session.codexRetryStatus == nil }
        #expect(backend.writes.isEmpty)
    }

    @Test func autoRetryPreferenceSurvivesReloadAndDefaultsToEnabled() throws {
        let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
        let store = fixture.makeStore()
        #expect(store.autoRetryCodexFailures)
        store.autoRetryCodexFailures = false
        #expect(!fixture.makeStore().autoRetryCodexFailures)
    }

    @Test func nativeCLIHandoffCancelsRecoveryBeforeReleasingTheWriter() async throws {
        let (_, store, session, server, clock) = try await nativeFixture()
        server.fail()
        try await waitForPuckState { clock.waits.count == 1 }
        let terminal = try await store.fallbackCodexSessionToCLI(id: session.id)
        try await waitForPuckState { clock.waits.isEmpty }
        #expect(terminal.id == session.id)
        #expect(terminal.codexBinding?.threadID == "retry-thread")
        #expect(session.codexRetryStatus == nil)
        #expect(server.turns.count == 1)
    }

    @Test func terminalNewUserTaskCanRetryEvenWhenExecutionIsTooFastToObserve() async throws {
        let (_, store, session, backend, clock) = try await terminalFixture()
        _ = store.applySupervisorResults([try terminalObservation(store, session)])
        try await waitForPuckState { clock.waits.count == 1 }
        store.noteCodexRetryInteraction(session)
        try await waitForPuckState { clock.waits.isEmpty }
        session.noteUserSubmittedInput("A different task")
        backend.lock.withLock { backend.screen = backend.screen.replacingOccurrences(of: "Read files", with: "A different task") }
        _ = store.applySupervisorResults([try terminalObservation(store, session)])
        try await waitForPuckState { clock.waits.count == 1 }
        #expect(session.codexRetryStatus?.attempt == 1)
        session.codexAutoRetry.cancel()
    }

    @Test func terminalIdenticalFailuresAfterAutomaticTurnsUseTheFourAttemptBudget() async throws {
        let (_, store, session, backend, clock) = try await terminalFixture()
        let failedScreen = backend.screen
        for attempt in 1...4 {
            backend.lock.withLock { backend.screen = failedScreen }
            _ = store.applySupervisorResults([try terminalObservation(store, session)])
            try await waitForPuckState { clock.waits.count == 1 }
            #expect(session.codexRetryStatus?.attempt == attempt)
            clock.advance()
            try await waitForPuckState { backend.writes.count == attempt * 2 && session.codexRetryStatus == nil }
            backend.lock.withLock { backend.screen = "Working\nEsc to interrupt" }
            _ = store.applySupervisorResults([try terminalObservation(store, session)])
        }
        backend.lock.withLock { backend.screen = failedScreen }
        _ = store.applySupervisorResults([try terminalObservation(store, session)])
        #expect(session.codexRetryStatus?.isExhausted == true)
        #expect(backend.writes.count == 8)
        session.codexAutoRetry.cancel()
    }

    @Test func terminalRecoveryWaitsForAnAgentSlotAndCanBeCancelledInTheQueue() async throws {
        let (_, store, session, backend, clock) = try await terminalFixture()
        store.maximumConcurrentAgents = 1
        store.agentAdmission.release(session.id)
        store.agentAdmission.adopt("other-active-task")
        _ = store.applySupervisorResults([try terminalObservation(store, session)])
        try await waitForPuckState { clock.waits.count == 1 }
        clock.advance()
        try await waitForPuckState { store.agentAdmission.queuedIDs.contains(session.id) }
        #expect(backend.writes.isEmpty)
        session.codexAutoRetry.cancel()
        try await waitForPuckState { !store.agentAdmission.queuedIDs.contains(session.id) }
        store.agentAdmission.release("other-active-task")
        #expect(backend.writes.isEmpty)
        #expect(session.freezeInputInFlight == 0)
    }

    private func nativeFixture() async throws -> (PuckStoreFixture, SessionStore, CodexSession, RetryServer, RetryClock) {
        let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
        let server = RetryServer(home: fixture.home.path)
        let store = fixture.makeStore(codexService: server, sessionBackend: AdmissionTerminalBackend())
        store.enableNativeCodex = true
        let session = try await store.createCodexSession(settings: .init(model: "fixture-model"), cwd: fixture.project.path, id: "retry-native")
        let clock = RetryClock()
        session.codexAutoRetry.sleep = { _ in try await clock.sleep() }
        session.draft = "Original task"
        await session.sendDraft()
        try await waitForPuckState { session.state.activeTurnID == server.currentTurnID }
        return (fixture, store, session, server, clock)
    }

    private func terminalFixture() async throws -> (PuckStoreFixture, SessionStore, TerminalSession, RetryTerminalBackend, RetryClock) {
        _ = NSApplication.shared
        let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
        let backend = RetryTerminalBackend()
        let store = SessionStore(persistence: fixture.persistence, tmuxBackend: backend, sessionBackend: backend,
            processTable: RetryProcessTable(backend: backend), historyBackend: DefaultSessionHistoryBackend(homeDirectory: fixture.home),
            detector: AgentStateDetector(rules: []),
            host: HostRuntimeContext(environment: ["PATH": "/usr/bin:/bin", "SHELL": "/bin/zsh", "HOME": fixture.home.path],
                homeDirectory: fixture.home, currentDirectory: fixture.project.path),
            telemetry: banyanTestTelemetry, attentionNotifier: AttentionNotifier(), puckDaemon: FakePuckDaemon())
        let session = store.spawn(id: "retry-terminal", cwd: fixture.project.path, command: "codex", select: false)
        let clock = RetryClock()
        session.codexAutoRetry.sleep = { _ in try await clock.sleep() }
        try await waitForPuckState { session.isProcessStarted }
        return (fixture, store, session, backend, clock)
    }

    private func terminalObservation(_ store: SessionStore, _ session: TerminalSession) throws -> SessionStatusObservation {
        let result = try #require(AgentSupervisor(backend: store.tmuxBackend, processTable: store.processTable.snapshot())
            .inspect(tmuxSessionName: session.tmuxSessionName, launchCommand: session.command, currentStatus: session.status))
        return .init(id: session.id, status: result.status, tone: result.tone, provider: result.provider,
            currentPath: result.currentPath, codexRetryCandidate: result.codexRetryCandidate)
    }
}
