import AppKit
import Foundation
import Testing
@testable import Banyan
@testable import BanyanCore

@MainActor
private final class NativeSessionServer: CodexThreadService {
    var calls: [(String, CodexJSONValue)] = []
    var continuations: [AsyncStream<CodexAppServerEvent>.Continuation] = []
    var starts = 0
    var failResume = false
    var onStart: (() -> Void)?

    func events() async -> AsyncStream<CodexAppServerEvent> {
        AsyncStream { continuations.append($0) }
    }
    func setServerRequestHandler(_ handler: CodexAppServerClient.RequestHandler?) async {}
    func request(_ method: String, params: CodexJSONValue) async throws -> CodexJSONValue {
        calls.append((method, params))
        if method == "thread/start" { onStart?(); starts += 1 }
        if method == "thread/resume", failResume {
            throw CodexAppServerError.remote(code: -32600, message: "thread already has an active writer")
        }
        if method == "thread/unsubscribe" { return .object(["status": .string("unsubscribed")]) }
        return .object(["thread": .object([
            "id": params.objectValue?["threadId"] ?? .string("native-thread-\(starts)"),
            "status": .object(["type": .string("idle")])
        ])])
    }
    func status(_ type: String, flags: [String] = []) {
        for continuation in continuations {
            continuation.yield(.notification(method: "thread/status/changed", params: .object([
                "threadId": .string("native-thread-1"),
                "status": .object(["type": .string(type), "activeFlags": .array(flags.map(CodexJSONValue.string))])
            ])))
        }
    }
}

@Suite(.serialized)
@MainActor
struct NativeCodexSessionTests {
    @Test func nativeCodexStorePersistsAndRestoresMappedSessionsWithoutTmux() async throws {
        let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
        let server = NativeSessionServer()
        let store = fixture.makeNativeStore(codexService: server)
        server.onStart = {
            #expect(fixture.persistence.load().first?.codex?.creationAttempted == true)
        }
        let settings = CodexThreadSettings(model: "test-model", approvalPolicy: "untrusted", sandbox: "read-only")
        let session = try await store.createCodexSession(settings: settings, cwd: fixture.project.path, id: "native")
        #expect(session.backendKind == .codex)
        #expect(session.agentSessionID == "native-thread-1")
        #expect(session.persistedTmuxSessionName == nil)
        #expect(session.cwd == fixture.project.path)
        #expect(session.persistenceSnapshot.codex?.settings == settings)
        // create returns only after the stable mapping has reached private SQLite.
        #expect(fixture.persistence.load().first?.codex?.threadID == "native-thread-1")

        let restored = fixture.makeNativeStore(codexService: server)
        restored.loadPersistedSessionsIfNeeded()
        let row = try #require(restored.sessions.first as? CodexSession)
        try await waitForPuckState { row.state.connection == .subscribed }
        #expect(row.id == session.id)
        #expect(row.state.binding == session.state.binding)
        #expect(server.starts == 1)
        #expect(server.calls.contains { $0.0 == "thread/resume" && $0.1.objectValue?["threadId"] == .string("native-thread-1") })
    }

    @Test func nativeCodexRowsSurviveSupervisorAndPuckCatalogSynchronization() async throws {
        let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
        let server = NativeSessionServer()
        let store = fixture.makeNativeStore(codexService: server)
        let session = try await store.createCodexSession(cwd: fixture.project.path, id: "native")
        server.status("active", flags: ["waitingOnApproval"])
        try await waitForPuckState { session.status == .asking }
        // A stale terminal observation cannot close or mutate a native row.
        store.applySupervisorResults([SessionStatusObservation(id: session.id, status: .closed,
            tone: .neutral, provider: nil, currentPath: "/tmp/other")])
        store.applyPuckSummaries([], closingMissing: true)
        #expect(store.sessions.map(\.id) == [session.id])
        #expect(store.visibleSessions.contains { $0.id == session.id })
        #expect(session.status == .asking)
        #expect(session.cwd == fixture.project.path)
        #expect(session.state.binding.threadID == "native-thread-1")
    }

    @Test func nativeCodexWindowlessStartupRestoresThePrivateMappingOnce() async throws {
        let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
        let server = NativeSessionServer()
        let store = fixture.makeNativeStore(codexService: server)
        let original = try await store.createCodexSession(cwd: fixture.project.path, id: "native")
        var control: ControlServer?
        let restored = fixture.makeNativeStore(codexService: server, makeControlServer: { store, host in
            let listener = ControlServer(store: store, host: host, port: .any)
            control = listener
            return listener
        })
        defer { control?.stop(); restored.stopPuckObservation() }
        let delegate = AppDelegate(startRuntime: restored.startRuntimeIfNeeded)
        delegate.applicationWillFinishLaunching(Notification(name: NSApplication.willFinishLaunchingNotification))
        delegate.applicationWillFinishLaunching(Notification(name: NSApplication.willFinishLaunchingNotification))
        let row = try #require(restored.sessions.first as? CodexSession)
        try await waitForPuckState { row.state.connection == .subscribed && control?.listeningPort != nil }
        #expect(restored.sessions.count == 1)
        #expect(row.state.binding == original.state.binding)
        #expect(server.starts == 1)
    }

    @Test func nativeCodexSelectionParkingAndApprovalStatesUseTheCoordinator() async throws {
        let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
        let server = NativeSessionServer()
        let store = fixture.makeNativeStore(codexService: server)
        let session = try await store.createCodexSession(cwd: fixture.project.path, id: "native")
        store.selectedSessionID = nil
        try await waitForPuckState { session.state.connection == .unsubscribed }
        store.selectedSessionID = session.id
        try await waitForPuckState { session.state.connection == .subscribed }
        #expect(server.starts == 1)
        server.status("active", flags: ["waitingOnApproval"])
        try await waitForPuckState { session.status == .asking }
        #expect(throws: ControlError.self) { try store.suspend(id: session.id) }
        #expect(session.isSuspended == false)
        store.selectedSessionID = nil
        try await Task.sleep(for: .milliseconds(30))
        #expect(session.state.isSubscribed)
        server.status("idle")
        try await waitForPuckState { session.state.connection == .unsubscribed }
        try store.suspend(id: session.id)
        #expect(session.isSuspended)
        try store.resume(id: session.id)
        #expect(!session.isSuspended)
        try await waitForPuckState { server.calls.filter { $0.0 == "thread/resume" }.count == 2 }
    }

    @Test func nativeCodexWriterConflictIsPublishedAndReopenPreservesIdentity() async throws {
        let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
        let server = NativeSessionServer()
        let store = fixture.makeNativeStore(codexService: server)
        let session = try await store.createCodexSession(cwd: fixture.project.path, id: "native")
        store.selectedSessionID = nil
        try await waitForPuckState { session.state.connection == .unsubscribed }
        server.failResume = true
        store.selectedSessionID = session.id
        try await waitForPuckState { session.status == .failed }
        guard case .writerConflict = session.state.connection else { Issue.record("Expected actionable writer conflict"); return }
        #expect(session.state.connection.message?.contains("Exit or detach") == true)
        #expect(session.persistenceSnapshot.codex?.threadID == "native-thread-1")
        server.failResume = false
        try store.close(id: session.id)
        try store.respawn(id: session.id)
        try await waitForPuckState { session.state.connection == .subscribed }
        #expect(server.starts == 1)
        #expect(session.status != .closed)
    }

    @Test func nativeCodexRemovedIDsCannotInheritAnOldThreadOrSettings() async throws {
        let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
        let server = NativeSessionServer()
        let store = fixture.makeNativeStore(codexService: server)
        let first = try await store.createCodexSession(settings: .init(model: "old-model"),
            cwd: fixture.project.path, id: "reused")
        try store.remove(id: first.id)
        let next = try await store.createCodexSession(settings: .init(model: "new-model"),
            cwd: fixture.home.path, id: "reused")
        #expect(next.id != first.id)
        #expect(next.state.binding.threadID == "native-thread-2")
        #expect(next.state.binding.settings.model == "new-model")
        #expect(next.cwd == fixture.home.path)
        #expect(store.codexThreads.states[first.id]?.binding.threadID == "native-thread-1")
        #expect(store.codexThreads.states[first.id]?.binding.settings.model == "old-model")
        server.status("idle")
        try await waitForPuckState { store.codexThreads.states[first.id]?.isSubscribed == false }
        #expect(store.codexThreads.reserves(sessionID: first.id))
        #expect(server.starts == 2)
    }

    @Test func nativeCodexBusyRowsCannotBeRemovedOrPrunedAndCanReopenFromHistory() async throws {
        let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
        let server = NativeSessionServer()
        let store = fixture.makeNativeStore(codexService: server)
        let session = try await store.createCodexSession(cwd: fixture.project.path, id: "busy")
        server.status("active", flags: ["waitingOnApproval"])
        try await waitForPuckState { session.status == .asking }
        do {
            try store.remove(id: session.id)
            Issue.record("Removing a pending native request must be rejected")
        } catch {
            #expect(error.localizedDescription.contains("answer pending requests"))
        }
        #expect(store.sessions.contains { $0.id == session.id })
        #expect(session.state.isSubscribed)
        try store.close(id: session.id)
        session.updatedAt = Date(timeIntervalSince1970: 0)
        #expect(store.pruneExpiredSessions(retentionDays: 1) == 0)
        #expect(store.sessions.contains { $0.id == session.id })
        #expect(throws: ControlError.self) { try store.remove(id: session.id) }
        try store.respawn(id: session.id)
        #expect(session.status == .asking)
        #expect(session.state.needsAttention)
        #expect(session.state.isSubscribed)
        #expect(server.starts == 1)
        #expect(!server.calls.contains { $0.0 == "turn/interrupt" })
    }
}

@MainActor
private extension PuckStoreFixture {
    func makeNativeStore(codexService: any CodexThreadService,
                         makeControlServer: @escaping (SessionStore, HostRuntimeContext) -> ControlServer = {
                             ControlServer(store: $0, host: $1)
                         }) -> SessionStore {
        makeStore(codexService: codexService,
            tmuxBackend: TmuxBackend(environment: ["PATH": "/usr/bin:/bin"], workingDirectory: project.path,
                socketName: "banyan-native-test-\(root.lastPathComponent)"),
            makeControlServer: makeControlServer)
    }
}
