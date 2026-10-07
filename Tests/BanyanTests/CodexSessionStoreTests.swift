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
    var connectionError: CodexAppServerError?
    var requestError: CodexAppServerError?
    var requestErrorMethod: String?
    var handoffs = 0
    var effectiveHome: String?
    func storageHome() async -> String? { effectiveHome }

    func connect() async throws {
        if let connectionError { throw connectionError }
    }
    func disconnectForHandoff() async throws { handoffs += 1 }

    func requestWhileConnected(_ method: String, params: CodexJSONValue) async throws -> CodexJSONValue {
        try await request(method, params: params)
    }
    func events() async -> AsyncStream<CodexAppServerEvent> {
        AsyncStream { continuations.append($0) }
    }
    func setServerRequestHandler(_ handler: CodexAppServerClient.RequestHandler?) async {}
    func request(_ method: String, params: CodexJSONValue) async throws -> CodexJSONValue {
        calls.append((method, params))
        if let requestError, requestErrorMethod == nil || requestErrorMethod == method { throw requestError }
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
    @Test func queuedNativeCreationPreservesSettingsOnCancelAndNeverStealsLaterSelection() async throws {
        let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
        let server = NativeSessionServer()
        let store = fixture.makeStore(codexService: server,
            freezePreferences: UserDefaults(suiteName: "banyan-admission-\(UUID().uuidString)")!)
        store.enableNativeCodex = true
        store.maximumConcurrentAgents = 1
        store.agentAdmission.adopt("existing-work")
        let settings = CodexThreadSettings(model: "synthetic-model", approvalPolicy: "untrusted")
        let creation = Task { try await store.createCodexSession(settings: settings, cwd: fixture.project.path, id: "queued", select: true) }
        try await waitForPuckState { store.sessions.first { $0.id == "queued" }?.agentQueuePosition == 1 }
        #expect(store.selectedSessionID == "queued" && server.starts == 0)
        store.cancelQueuedAgent(id: "queued")
        await #expect(throws: CancellationError.self) { try await creation.value }
        let row = try #require(store.sessions.first as? CodexSession)
        #expect(row.state.binding.settings == settings && row.state.binding.threadID == nil)
        store.selectedSessionID = nil
        store.agentAdmission.release("existing-work")
        try await store.codexThreads.connect(sessionID: row.id)
        #expect(store.selectedSessionID == nil && server.starts == 1)
    }

    @Test func admittedNativeCreationRespectsSelectionChangedWhileQueued() async throws {
        let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
        let server = NativeSessionServer()
        let store = fixture.makeStore(codexService: server,
            freezePreferences: UserDefaults(suiteName: "banyan-admission-\(UUID().uuidString)")!)
        store.enableNativeCodex = true
        store.maximumConcurrentAgents = 1
        store.agentAdmission.adopt("existing-work")
        let creation = Task { try await store.createCodexSession(cwd: fixture.project.path, id: "queued", select: true) }
        try await waitForPuckState { store.agentAdmission.queuedIDs == ["queued"] }
        store.selectedSessionID = nil
        try await waitForPuckState { store.codexThreads.selectedSessionID == nil }
        store.agentAdmission.release("existing-work")
        _ = try await creation.value
        #expect(store.selectedSessionID == nil && server.starts == 0)
    }

    @Test func restoredHiddenAndUnknownNativeWorkKeepsDurableAdmissionReservations() throws {
        let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
        let snapshots = [SessionStatus.closed, .failed].enumerated().map { index, status in
            SessionSnapshot(id: "uncertain-\(index)", tmuxSessionName: nil, title: "Synthetic native work",
                reportedTitle: nil, cwd: fixture.project.path, command: "", status: status, tone: .neutral,
                agentSlotReserved: true, createdAt: Date(), updatedAt: Date(), backend: .codex,
                codex: .init(threadID: "stored-\(index)", cwd: fixture.project.path))
        }
        fixture.persistence.save(snapshots)
        let defaults = UserDefaults(suiteName: "banyan-admission-\(UUID().uuidString)")!
        defaults.set(1, forKey: AgentAdmissionController.defaultsKey)
        let server = NativeSessionServer()
        let store = fixture.makeStore(codexService: server, sessionBackend: AdmissionTerminalBackend(), freezePreferences: defaults)
        store.enableNativeCodex = false
        store.loadPersistedSessionsIfNeeded()
        #expect(store.agentAdmission.running == Set(snapshots.map(\.id)))
        #expect(store.sessions.map(\.persistenceSnapshot).allSatisfy { $0.agentSlotReserved })
        let queued = store.spawn(id: "queued", cwd: fixture.project.path, command: "synthetic-agent", select: false)
        #expect(queued.agentQueuePosition == 1)
        #expect(server.starts == 0)
    }

    @Test func nativeProvenanceUsesEffectiveServerHomeInsteadOfRawHostHome() async throws {
        let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
        let server = NativeSessionServer()
        let resolvedHome = fixture.root.appendingPathComponent("shell-codex-home").path
        server.effectiveHome = resolvedHome
        let store = fixture.makeNativeStore(codexService: server)
        let native = try await store.createCodexSession(cwd: fixture.project.path, id: "native")
        #expect(native.codexBinding?.codexHome == resolvedHome)
        #expect(native.codexBinding?.codexHome != fixture.home.appendingPathComponent(".codex").path)
        try store.suspend(id: native.id)
        try await waitForPuckState { !native.state.isSubscribed }
        let fallback = try await store.fallbackCodexSessionToCLI(id: native.id)
        #expect(fallback.command.contains("'CODEX_HOME=" + resolvedHome + "'"))
        #expect(fixture.persistence.load().first?.codex?.codexHome == resolvedHome)
    }

    @Test func nativeStartupFailuresLeaveNoRowsOrReservedIDs() async throws {
        for failure in [CodexAppServerError.launch("missing executable"), .incompatibleVersion("0.999.0")] {
            let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
            let server = NativeSessionServer()
            server.connectionError = failure
            let store = fixture.makeNativeStore(codexService: server)
            do {
                _ = try await store.createCodexSession(cwd: fixture.project.path, id: "rejected")
                Issue.record("Expected startup failure")
            } catch { #expect(error as? CodexAppServerError == failure) }
            #expect(store.sessions.isEmpty)
            #expect(fixture.persistence.load().isEmpty)
            #expect(!store.codexThreads.reserves(sessionID: "rejected"))
            #expect(server.calls.isEmpty)
        }
    }

    @Test func missingStartCapabilityRollsBackAnUncreatedRow() async throws {
        let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
        let server = NativeSessionServer()
        server.requestError = .remote(code: -32601, message: "thread/start unavailable")
        let store = fixture.makeNativeStore(codexService: server)
        do {
            _ = try await store.createCodexSession(cwd: fixture.project.path, id: "rejected")
            Issue.record("Expected unavailable capability")
        } catch { #expect(error.localizedDescription.contains("thread/start unavailable")) }
        #expect(store.sessions.isEmpty)
        #expect(fixture.persistence.load().isEmpty)
        #expect(!store.codexThreads.reserves(sessionID: "rejected"))
        #expect(store.codexThreads.selectedSessionID == nil)
    }

    @Test func failedSelectedCreationRestoresThePreviousNativeSelection() async throws {
        let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
        let server = NativeSessionServer()
        let store = fixture.makeNativeStore(codexService: server)
        let previous = try await store.createCodexSession(cwd: fixture.project.path, id: "previous")
        #expect(previous.state.isSubscribed)
        server.requestErrorMethod = "thread/start"
        server.requestError = .remote(code: -32601, message: "thread/start unavailable")
        await #expect(throws: CodexAppServerError.self) {
            try await store.createCodexSession(cwd: fixture.project.path, id: "rejected")
        }
        #expect(store.sessions.map(\.id) == [previous.id])
        #expect(store.selectedSessionID == previous.id)
        #expect(store.codexThreads.selectedSessionID == previous.id)
        #expect(previous.state.isSubscribed)
        #expect(previous.state.binding.threadID == "native-thread-1")
        #expect(!store.codexThreads.reserves(sessionID: "rejected"))
    }

    @Test func nativeRolloutGatePersistsIndependentlyAndDoesNotReconnectRestoredRows() async throws {
        let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
        let server = NativeSessionServer()
        let store = fixture.makeNativeStore(codexService: server)
        let native = try await store.createCodexSession(cwd: fixture.project.path, id: "native")
        store.enableCodexAppServerMode = true
        store.enableNativeCodex = false
        await store.codexThreads.flushPersistence?()
        let restored = fixture.makeStore(codexService: server,
            tmuxBackend: TmuxBackend(environment: ["PATH": "/usr/bin:/bin"],
                workingDirectory: fixture.project.path, socketName: "banyan-native-disabled-test"))
        restored.loadPersistedSessionsIfNeeded()
        #expect(!restored.enableNativeCodex)
        #expect(restored.enableCodexAppServerMode)
        #expect(restored.sessions.first?.agentSessionID == native.agentSessionID)
        do {
            _ = try await restored.createCodexSession(cwd: fixture.project.path, id: "disabled")
            Issue.record("Expected native rollout gate")
        } catch { #expect(error.localizedDescription.contains("disabled")) }
        #expect(server.starts == 1)
        #expect(!server.calls.contains { $0.0 == "thread/resume" })
    }

    @Test func nativeFallbackAfterResumeFailurePreservesIdentitySettingsAndControlProvenance() async throws {
        let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
        let server = NativeSessionServer()
        let store = fixture.makeNativeStore(codexService: server)
        let settings = CodexThreadSettings(model: "test-model", modelProvider: "custom",
            approvalPolicy: "untrusted", sandbox: "read-only", config: ["model_reasoning_effort": .string("high")])
        let native = try await store.createCodexSession(settings: settings, cwd: fixture.project.path, id: "native")
        // Park to keep this test independent of installed terminal executables.
        try store.suspend(id: native.id)
        try await waitForPuckState { !native.state.isSubscribed }
        for failure in [CodexAppServerError.launch("server missing"), .incompatibleVersion("0.999.0"), .remote(code: -32601, message: "thread/resume unavailable")] {
            switch failure {
            case .launch, .incompatibleVersion: server.connectionError = failure; server.requestError = nil
            default: server.connectionError = nil; server.requestError = failure
            }
            do { try await store.codexThreads.connect(sessionID: native.id) } catch {}
            #expect(native.agentSessionID == "native-thread-1")
        }
        store.enableCodexAppServerMode = true
        let terminal = try await store.fallbackCodexSessionToCLI(id: native.id)
        #expect(terminal.id == native.id)
        #expect(terminal.agentSessionID == "native-thread-1")
        #expect(terminal.agentProvider == .codex)
        #expect(terminal.nativeCodexProvenance?.settings == settings)
        #expect(terminal.nativeCodexProvenance?.codexHome == fixture.home.appendingPathComponent(".codex").path)
        #expect(terminal.command.contains("'resume' 'native-thread-1'"))
        #expect(!terminal.command.contains("remote-control"))
        #expect(server.handoffs == 1)
        #expect(server.starts == 1)
        native.touch() // A queued callback from the replaced object cannot undo handoff.
        await Task.yield()
        await store.codexThreads.flushPersistence?()
        #expect(fixture.persistence.load().first?.codex == terminal.nativeCodexProvenance)
        #expect(fixture.persistence.load().first?.backend == .terminal)
        let summary = ControlServer(store: store, host: HostRuntimeContext(environment: ["PATH": "/usr/bin:/bin"], homeDirectory: fixture.home, currentDirectory: fixture.project.path)).summary(terminal)
        let binding = try #require(summary["codex"] as? [String: Any])
        #expect(binding["threadID"] as? String == "native-thread-1")
        #expect(binding["cliFallbackReason"] as? String != nil)
        let restored = fixture.makeNativeStore(codexService: server)
        restored.loadPersistedSessionsIfNeeded()
        let row = try #require(restored.sessions.first as? TerminalSession)
        #expect(row.id == native.id)
        #expect(row.nativeCodexProvenance == terminal.nativeCodexProvenance)
        #expect(row.command == terminal.command)
        // Changing the legacy remote-control preference cannot rewrite fallback
        // provenance when reopening from history.
        try restored.close(id: row.id)
        try restored.respawn(id: row.id)
        #expect(row.command == terminal.command)
        #expect(server.starts == 1)
    }

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
        if let server = codexService as? NativeSessionServer, server.effectiveHome == nil {
            server.effectiveHome = home.appendingPathComponent(".codex").path
        }
        let store = makeStore(codexService: codexService,
            tmuxBackend: TmuxBackend(environment: ["PATH": "/usr/bin:/bin"], workingDirectory: project.path,
                socketName: "banyan-native-test-\(root.lastPathComponent)"),
            makeControlServer: makeControlServer)
        store.enableNativeCodex = true
        return store
    }
}
