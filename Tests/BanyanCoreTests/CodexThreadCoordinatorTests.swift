import Foundation
import Testing
@testable import BanyanCore

@MainActor
private final class ThreadServer: CodexThreadService {
    struct Call { let method: String; let params: [String: CodexJSONValue] }
    var calls: [Call] = []
    var threads: [String: CodexJSONValue] = [:]
    var failures: [String: CodexAppServerError] = [:]
    var beforeResponse: ((String) async -> Void)?
    var handler: CodexAppServerClient.RequestHandler?
    var streams: [AsyncStream<CodexAppServerEvent>.Continuation] = []
    var starts = 0
    var connectionError: CodexAppServerError?
    var effectiveModel: String?

    func connect() async throws {
        if let connectionError { throw connectionError }
    }

    func events() async -> AsyncStream<CodexAppServerEvent> {
        AsyncStream { streams.append($0) }
    }
    func setServerRequestHandler(_ handler: CodexAppServerClient.RequestHandler?) async { self.handler = handler }
    func request(_ method: String, params: CodexJSONValue) async throws -> CodexJSONValue {
        let params = params.objectValue ?? [:]
        calls.append(Call(method: method, params: params))
        await beforeResponse?(method)
        if let failure = failures[method] { throw failure }
        let id = params["threadId"]?.stringValue ?? ""
        switch method {
        case "thread/start":
            starts += 1
            let id = "thread-\(starts)"
            let thread: CodexJSONValue = .object([
                "id": .string(id), "cwd": params["cwd"] ?? .null,
                "status": .object(["type": .string("idle")])
            ])
            threads[id] = thread
            var result: [String: CodexJSONValue] = ["thread": thread]
            if let effectiveModel { result["model"] = .string(effectiveModel) }
            return .object(result)
        case "thread/resume", "thread/read":
            guard let thread = threads[id] else { throw CodexAppServerError.remote(code: -32600, message: "no rollout found for thread \(id)") }
            return .object(["thread": thread])
        case "thread/list": return .object(["data": .array(Array(threads.values)), "nextCursor": .null])
        case "thread/unsubscribe": return .object(["status": .string("unsubscribed")])
        case "turn/start": return .object(["turn": .object(["id": .string("turn-1"), "status": .string("inProgress")])])
        case "turn/interrupt": return .object([:])
        default: throw CodexAppServerError.protocolViolation("Unexpected method \(method)")
        }
    }
    func emit(_ method: String, id: String, fields: [String: CodexJSONValue] = [:]) {
        var params = fields
        params["threadId"] = .string(id)
        if let status = fields["status"], var thread = threads[id]?.objectValue {
            thread["status"] = status
            threads[id] = .object(thread)
        }
        for stream in streams { stream.yield(.notification(method: method, params: .object(params))) }
    }
    func disconnect() {
        for stream in streams { stream.yield(.disconnected(.disconnected("test restart"))) }
    }
    func count(_ method: String) -> Int { calls.filter { $0.method == method }.count }
}

@MainActor
private func eventually(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !condition() {
        if ContinuousClock.now >= deadline { throw CodexAppServerError.timedOut("test condition") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
private func coordinator(_ server: ThreadServer, id: String = "session", threadID: String? = nil) throws -> CodexThreadCoordinator {
    let coordinator = CodexThreadCoordinator(service: server)
    try coordinator.register(sessionID: id, binding: .init(threadID: threadID, cwd: "/tmp/project"))
    return coordinator
}

@Test @MainActor func codexThreadsPersistIdentityAcrossSelectionAndServerRestart() async throws {
    let server = ThreadServer()
    let manager = try coordinator(server)
    try await manager.select(sessionID: "session")
    let binding = try #require(manager.states["session"]?.binding)
    #expect(binding.threadID == "thread-1")
    try await manager.select(sessionID: nil)
    #expect(manager.states["session"]?.connection == .unsubscribed)
    #expect(manager.states["session"]?.runtime.type == "idle") // Unsubscribe is not unload.
    server.emit("thread/closed", id: "thread-1")
    try await eventually { manager.states["session"]?.runtime.type == "notLoaded" }
    try await manager.select(sessionID: "session")
    #expect(server.count("thread/resume") == 1)
    server.disconnect()
    try await eventually { manager.states["session"]?.isSubscribed == false }
    try await manager.select(sessionID: "session")
    #expect(server.count("thread/resume") == 2)
    let restored = CodexThreadCoordinator(service: server)
    try restored.register(sessionID: "session", binding: binding)
    try await restored.select(sessionID: "session")
    #expect(restored.states["session"]?.binding == binding)
    #expect(server.count("thread/start") == 1)
    #expect(server.count("thread/resume") == 3)
}

@Test @MainActor func codexThreadsReapplyCwdAndSettingsWithoutCrossThreadLeakage() async throws {
    let server = ThreadServer()
    let manager = CodexThreadCoordinator(service: server)
    let settings = CodexThreadSettings(model: "test-model", modelProvider: "test-provider",
        approvalPolicy: "untrusted", sandbox: "read-only", config: ["model_reasoning_effort": .string("high")])
    try manager.register(sessionID: "first", binding: .init(cwd: "/tmp/worktree", settings: settings))
    try manager.register(sessionID: "second", binding: .init(cwd: "/tmp/other"))
    try await manager.select(sessionID: "first")
    let started = try #require(server.calls.last(where: { $0.method == "thread/start" }))
    #expect(started.params == settings.parameters(cwd: "/tmp/worktree"))
    try await manager.select(sessionID: "second")
    #expect(server.calls.last(where: { $0.method == "thread/start" })?.params["model"] == nil)
    try await manager.select(sessionID: "first")
    var expected = settings.parameters(cwd: "/tmp/worktree")
    expected["threadId"] = .string("thread-1")
    #expect(server.calls.last(where: { $0.method == "thread/resume" })?.params == expected)
}

@Test @MainActor func codexThreadsKeepActiveBackgroundTurnsUntilTheyFinish() async throws {
    let server = ThreadServer()
    let manager = try coordinator(server)
    try await manager.select(sessionID: "session")
    _ = try await manager.startTurn(sessionID: "session", input: [.object(["type": .string("text"), "text": .string("hello")])])
    try await manager.select(sessionID: nil)
    #expect(manager.states["session"]?.activeTurnID == "turn-1")
    #expect(server.count("thread/unsubscribe") == 0)
    await #expect(throws: CodexAppServerError.self) { try await manager.detach(sessionID: "session") }
    server.emit("turn/completed", id: "thread-1", fields: ["turn": .object(["id": .string("turn-1"), "status": .string("completed")])])
    try await eventually { manager.states["session"]?.connection == .unsubscribed }
    #expect(server.count("thread/unsubscribe") == 1)
}

@Test @MainActor func codexThreadsHoldApprovalsUntilTheServerResolvesThem() async throws {
    let server = ThreadServer()
    let manager = try coordinator(server)
    try await manager.select(sessionID: "session")
    let handler = try #require(server.handler)
    let request = CodexServerRequest(id: .string("approval-1"), method: "item/commandExecution/requestApproval",
        params: .object(["threadId": .string("thread-1"), "turnId": .string("turn-1")]))
    let answer = Task { await handler(request) }
    try await eventually { manager.states["session"]?.needsAttention == true }
    try await manager.select(sessionID: nil)
    #expect(server.count("thread/unsubscribe") == 0)
    try manager.respond(sessionID: "session", requestID: request.id, reply: .result(.object(["decision": .string("accept")])))
    if case .result(let value) = await answer.value { #expect(value.objectValue?["decision"] == .string("accept")) }
    else { Issue.record("Approval was rejected") }
    #expect(manager.states["session"]?.needsAttention == true)
    server.emit("thread/status/changed", id: "thread-1", fields: ["status": .object(["type": .string("idle")])])
    try await eventually { manager.states["session"]?.runtime.type == "idle" }
    #expect(server.count("thread/unsubscribe") == 0)
    server.emit("serverRequest/resolved", id: "thread-1", fields: ["requestId": request.id])
    try await eventually { manager.states["session"]?.connection == .unsubscribed }
    #expect(throws: CodexAppServerError.self) {
        try manager.respond(sessionID: "session", requestID: request.id, reply: .result(.null))
    }
}

@Test @MainActor func codexThreadsRespectRestoredApprovalFlagsAndUnknownStatuses() async throws {
    let server = ThreadServer()
    server.threads["stored"] = .object(["id": .string("stored"), "status": .object([
        "type": .string("active"), "activeFlags": .array([.string("waitingOnApproval")])
    ])])
    let manager = try coordinator(server, threadID: "stored")
    try await manager.connect(sessionID: "session")
    #expect(manager.states["session"]?.needsAttention == true)
    #expect(server.count("thread/unsubscribe") == 0)
    server.emit("thread/status/changed", id: "stored", fields: ["status": .object(["type": .string("future-state")])])
    try await eventually { manager.states["session"]?.runtime.type == "future-state" }
    #expect(server.count("thread/unsubscribe") == 0)
}

@Test @MainActor func codexWriterConflictsAreActionableAndRetryTheSameMapping() async throws {
    let server = ThreadServer()
    server.threads["owned"] = .object(["id": .string("owned"), "status": .object(["type": .string("idle")])])
    server.failures["thread/resume"] = .remote(code: -32600, message: "thread owned already has an active writer")
    let manager = try coordinator(server, threadID: "owned")
    await #expect(throws: CodexAppServerError.self) { try await manager.select(sessionID: "session") }
    let state = try #require(manager.states["session"])
    guard case .writerConflict(let message) = state.connection else { Issue.record("Missing writer conflict"); return }
    #expect(message.contains("Exit or detach"))
    #expect(state.binding.threadID == "owned")
    _ = try await manager.read(sessionID: "session")
    _ = try await manager.list(cwd: "/tmp/project")
    #expect(manager.states["session"]?.isSubscribed == false)
    server.failures.removeValue(forKey: "thread/resume")
    try await manager.select(sessionID: "session")
    #expect(manager.states["session"]?.connection == .subscribed)
    #expect(server.count("thread/start") == 0)
}

@Test @MainActor func codexMissingRolloutsNeverCreateReplacementThreads() async throws {
    let server = ThreadServer()
    let manager = try coordinator(server, threadID: "no-history-yet")
    await #expect(throws: CodexAppServerError.self) { try await manager.select(sessionID: "session") }
    await #expect(throws: CodexAppServerError.self) { try await manager.connect(sessionID: "session") }
    guard case .unavailable = manager.states["session"]?.connection else { Issue.record("Missing unavailable state"); return }
    #expect(manager.states["session"]?.binding.threadID == "no-history-yet")
    #expect(server.count("thread/start") == 0)
}

@Test @MainActor func codexUncertainStartsRequireExplicitIdentityRecovery() async throws {
    let server = ThreadServer()
    let manager = try coordinator(server)
    server.failures["thread/start"] = .timedOut("thread/start")
    await #expect(throws: CodexAppServerError.self) { try await manager.select(sessionID: "session") }
    let persisted = try #require(manager.states["session"]?.binding)
    let restored = CodexThreadCoordinator(service: server)
    try restored.register(sessionID: "session", binding: persisted)
    await #expect(throws: CodexAppServerError.self) { try await restored.select(sessionID: "session") }
    #expect(server.count("thread/start") == 1)
    server.threads["recovered"] = .object(["id": .string("recovered"), "cwd": .string("/tmp/project"),
        "status": .object(["type": .string("idle")])])
    try await restored.recoverCreation(sessionID: "session", threadID: "recovered")
    #expect(restored.states["session"]?.binding.threadID == "recovered")
    #expect(server.count("thread/start") == 1)
}

@Test @MainActor func codexLateResumeCannotKeepAnIdleBackgroundSubscription() async throws {
    let server = ThreadServer()
    let manager = try coordinator(server)
    try manager.register(sessionID: "other", binding: .init(cwd: "/tmp/other"))
    try await manager.select(sessionID: "session")
    try await manager.select(sessionID: nil)
    var gate: CheckedContinuation<Void, Never>?
    server.beforeResponse = { method in
        if method == "thread/resume" { await withCheckedContinuation { gate = $0 } }
    }
    let first = Task { try await manager.select(sessionID: "session") }
    try await eventually { gate != nil }
    let second = Task { try await manager.select(sessionID: "other") }
    try await eventually { manager.selectedSessionID == "other" }
    gate?.resume()
    try await first.value
    try await second.value
    #expect(manager.states["session"]?.isSubscribed == false)
    #expect(manager.states["other"]?.isSubscribed == true)
    #expect(server.count("thread/start") == 2)
}

@Test @MainActor func codexActiveEventsDuringUnsubscribeCauseImmediateReattach() async throws {
    let server = ThreadServer()
    let manager = try coordinator(server)
    try await manager.select(sessionID: "session")
    server.beforeResponse = { method in
        if method == "thread/unsubscribe" {
            server.emit("turn/started", id: "thread-1", fields: ["turn": .object(["id": .string("external-turn")])])
            try? await eventually { manager.states["session"]?.activeTurnID == "external-turn" }
        }
    }
    try await manager.select(sessionID: nil)
    #expect(manager.states["session"]?.isSubscribed == true)
    #expect(server.count("thread/resume") == 1)
}

@Test @MainActor func codexDuplicateThreadBindingsAreRejected() throws {
    let manager = try coordinator(ThreadServer(), threadID: "shared")
    #expect(throws: CodexAppServerError.self) {
        try manager.register(sessionID: "duplicate", binding: .init(threadID: "shared", cwd: "/tmp/project"))
    }
    #expect(throws: CodexAppServerError.self) {
        try manager.register(sessionID: "session", binding: .init(cwd: "/tmp/different", settings: .init(model: "different")))
    }
}

@Test @MainActor func codexLaunchFailuresDoNotPoisonAnUnattemptedCreation() async throws {
    let server = ThreadServer()
    let manager = try coordinator(server)
    server.connectionError = .launch("executable unavailable")
    await #expect(throws: CodexAppServerError.self) { try await manager.select(sessionID: "session") }
    #expect(manager.states["session"]?.binding.creationAttempted == false)
    #expect(server.count("thread/start") == 0)
    server.connectionError = nil
    try await manager.select(sessionID: "session")
    #expect(server.count("thread/start") == 1)
}

@Test @MainActor func codexThreadsPinTheEffectiveDefaultModelOnResume() async throws {
    let server = ThreadServer()
    server.effectiveModel = "resolved-model"
    let manager = try coordinator(server)
    try await manager.select(sessionID: "session")
    #expect(manager.states["session"]?.binding.settings.model == "resolved-model")
    try await manager.select(sessionID: nil)
    try await manager.select(sessionID: "session")
    #expect(server.calls.last(where: { $0.method == "thread/resume" })?.params["model"] == .string("resolved-model"))
}

@Test @MainActor func codexThreadsInvalidatePendingRepliesOnDisconnect() async throws {
    let server = ThreadServer()
    let manager = try coordinator(server)
    try await manager.select(sessionID: "session")
    let handler = try #require(server.handler)
    let request = CodexServerRequest(id: .integer(7), method: "item/fileChange/requestApproval",
        params: .object(["threadId": .string("thread-1")]))
    let reply = Task { await handler(request) }
    try await eventually { manager.states["session"]?.needsAttention == true }
    server.disconnect()
    try await eventually { manager.states["session"]?.isSubscribed == false }
    if case .error = await reply.value {} else { Issue.record("A disconnected approval must fail") }
    #expect(manager.states["session"]?.runtime.type == "unknown")
    #expect(manager.states["session"]?.binding.threadID == "thread-1")
    #expect(throws: CodexAppServerError.self) {
        try manager.respond(sessionID: "session", requestID: request.id, reply: .result(.null))
    }
}

@Test func codexBindingRoundTripsDatabaseJSONAndSnapshotUpdates() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let database = SessionDatabase(databaseURL: root.appendingPathComponent("state.sqlite"), legacyJSONURL: root.appendingPathComponent("sessions.json"))
    let binding = CodexThreadBinding(threadID: "stored-thread", cwd: "/tmp/worktree",
        settings: .init(model: "test-model", approvalPolicy: "untrusted", sandbox: "read-only"))
    let snapshot = SessionSnapshot(id: "native", tmuxSessionName: nil, title: "Native", reportedTitle: nil,
        cwd: binding.cwd, command: "", status: .asking, tone: .yellow,
        agentSessionID: binding.threadID, createdAt: Date(timeIntervalSince1970: 100),
        updatedAt: Date(timeIntervalSince1970: 100), backend: .codex, codex: binding)
    database.save([snapshot])
    #expect(database.load() == [snapshot])
    let updated = snapshot.updating(status: .idle)
    database.saveSession(updated, sortOrder: 0)
    #expect(database.load().first?.codex == binding)
    #expect(try JSONDecoder().decode(SessionSnapshot.self, from: JSONEncoder().encode(updated)) == updated)
}
