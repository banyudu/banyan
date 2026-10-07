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
    var onConnect: (() -> Void)?
    var effectiveModel: String?
    var handoffs = 0
    var connectedRequests: [String] = []
    var effectiveHome: String? = "/tmp/codex-test-store"
    var fallbackValidationError: CodexAppServerError?
    var duringFallbackValidation: (() async -> Void)?
    func storageHome() async -> String? { effectiveHome }
    func disconnectForHandoff() async throws { handoffs += 1 }
    func validateCLIFallback(binding: CodexThreadBinding) async throws {
        await duringFallbackValidation?()
        if let fallbackValidationError { throw fallbackValidationError }
    }

    func connect() async throws {
        onConnect?()
        if let connectionError { throw connectionError }
    }

    func requestWhileConnected(_ method: String, params: CodexJSONValue) async throws -> CodexJSONValue {
        connectedRequests.append(method)
        return try await request(method, params: params)
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
        case "turn/steer": return .object(["turnId": params["expectedTurnId"] ?? .null])
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

@Test @MainActor func codexCLIConfigRejectionPreservesNativeOwnershipAndSettings() async throws {
    let server = ThreadServer()
    let manager = try coordinator(server)
    try await manager.select(sessionID: "session")
    let binding = try #require(manager.states["session"]?.binding)
    server.fallbackValidationError = .protocolViolation("CLI no longer supports this approval policy")
    await #expect(throws: CodexAppServerError.self) {
        try await manager.prepareForCLIFallback(sessionID: "session")
    }
    #expect(server.handoffs == 0)
    #expect(manager.states["session"]?.binding == binding)
    #expect(manager.states["session"]?.isSubscribed == true)
    #expect(manager.selectedSessionID == "session")
    server.fallbackValidationError = nil
    _ = try await manager.startTurn(sessionID: "session", input: [])
    #expect(server.count("turn/start") == 1)
}

@Test @MainActor func codexFallbackDoesNotReapWorkArrivingDuringCLIConfigValidation() async throws {
    let server = ThreadServer()
    let manager = try coordinator(server)
    try await manager.select(sessionID: "session")
    server.duringFallbackValidation = {
        server.emit("turn/started", id: "thread-1", fields: ["turn": .object(["id": .string("external-turn")])])
        try? await eventually { manager.states["session"]?.activeTurnID == "external-turn" }
    }
    await #expect(throws: CodexAppServerError.self) {
        try await manager.prepareForCLIFallback(sessionID: "session")
    }
    #expect(server.handoffs == 0)
    #expect(manager.states["session"]?.activeTurnID == "external-turn")
    #expect(manager.states["session"]?.isSubscribed == true)
}

@Test @MainActor func codexSteeringAndInterruptKeepTheExpectedTurnAndPolicy() async throws {
    let server = ThreadServer()
    let manager = try coordinator(server)
    try await manager.select(sessionID: "session")
    _ = try await manager.startTurn(sessionID: "session", input: [.object(["type": .string("text"), "text": .string("Start")])])
    let input: [CodexJSONValue] = [.object(["type": .string("text"), "text": .string("Focus on tests")])]
    _ = try await manager.steer(sessionID: "session", expectedTurnID: "turn-1", input: input)
    #expect(server.calls.last?.params == ["threadId": .string("thread-1"), "expectedTurnId": .string("turn-1"), "input": .array(input)])
    await #expect(throws: CodexAppServerError.self) { try await manager.steer(sessionID: "session", expectedTurnID: "old-turn", input: input) }
    await #expect(throws: CodexAppServerError.self) { try await manager.interrupt(sessionID: "session", expectedTurnID: "old-turn") }
    try await manager.interrupt(sessionID: "session", expectedTurnID: "turn-1")
    #expect(server.calls.last?.params == ["threadId": .string("thread-1"), "turnId": .string("turn-1")])
    #expect(manager.states["session"]?.binding.settings.approvalPolicy == "on-request")
    #expect(manager.states["session"]?.binding.settings.sandbox == "workspace-write")
}

@Test @MainActor func codexDisableRejectsSteeringAndReenableKeepsTheActiveTurnIdentity() async throws {
    let server = ThreadServer()
    let manager = try coordinator(server)
    try await manager.select(sessionID: "session")
    _ = try await manager.startTurn(sessionID: "session", input: [])
    let original = manager.states["session"]?.binding
    manager.isEnabled = false
    try await manager.synchronizeRollout()
    let calls = server.calls.count
    await #expect(throws: CodexAppServerError.self) {
        try await manager.steer(sessionID: "session", expectedTurnID: "turn-1", input: [])
    }
    #expect(server.calls.count == calls)
    #expect(server.handoffs == 0)
    #expect(manager.states["session"]?.isSubscribed == true)
    #expect(manager.states["session"]?.activeTurnID == "turn-1")
    #expect(manager.states["session"]?.binding == original)
    manager.isEnabled = true
    try await manager.synchronizeRollout()
    _ = try await manager.steer(sessionID: "session", expectedTurnID: "turn-1", input: [])
    #expect(server.calls.last?.params["expectedTurnId"] == .string("turn-1"))
    #expect(server.count("thread/start") == 1)
    #expect(server.count("thread/resume") == 0)
}

@Test @MainActor func codexLateTurnCompletionDoesNotClearANewerTurnOrRequest() async throws {
    let server = ThreadServer()
    let manager = try coordinator(server)
    try await manager.select(sessionID: "session")
    server.emit("turn/started", id: "thread-1", fields: ["turn": .object(["id": .string("new-turn"), "status": .string("inProgress")])])
    try await eventually { manager.states["session"]?.activeTurnID == "new-turn" }
    let handler = try #require(server.handler)
    let request = CodexServerRequest(id: .integer(9), method: "item/fileChange/requestApproval", params: .object([
        "threadId": .string("thread-1"), "turnId": .string("new-turn")]))
    let reply = Task { await handler(request) }
    try await eventually { manager.states["session"]?.pendingRequests.count == 1 }
    server.emit("turn/completed", id: "thread-1", fields: ["turn": .object(["id": .string("old-turn"), "status": .string("completed")])])
    // The routed event is a deterministic barrier for the observation task.
    var routed = false
    manager.onEvent = { _, method, _ in if method == "turn/completed" { routed = true } }
    try await eventually { routed }
    #expect(manager.states["session"]?.activeTurnID == "new-turn")
    #expect(manager.states["session"]?.pendingRequests.count == 1)
    try manager.respond(sessionID: "session", requestID: request.id,
        reply: CodexConversationRequest(request).approvalReply(.decline))
    if case .result(let value) = await reply.value { #expect(value.objectValue?["decision"] == .string("decline")) }
    else { Issue.record("The newer request was canceled by an older turn") }
}

@Test @MainActor func codexTurnCompletionReleasesUnansweredContinuationsForThatTurn() async throws {
    let server = ThreadServer()
    let manager = try coordinator(server)
    try await manager.select(sessionID: "session")
    let handler = try #require(server.handler)
    let request = CodexServerRequest(id: .integer(11), method: "item/tool/requestUserInput", params: .object([
        "threadId": .string("thread-1"), "turnId": .string("turn-1")]))
    var finished = false
    let reply = Task { let result = await handler(request); finished = true; return result }
    try await eventually { manager.states["session"]?.pendingRequests.count == 1 }
    server.emit("turn/completed", id: "thread-1", fields: ["turn": .object(["id": .string("turn-1"), "status": .string("interrupted")])])
    try await eventually { finished }
    #expect(manager.states["session"]?.pendingRequests.isEmpty == true)
    if case .error = await reply.value {} else { Issue.record("Unanswered input should be invalidated on turn end") }
}

@Test @MainActor func codexHydrationIsTransientAndPreservesEventsDuringResume() async throws {
    let server = ThreadServer()
    let manager = try coordinator(server)
    try await manager.select(sessionID: "session")
    try await manager.select(sessionID: nil)
    server.threads["thread-1"] = .object(["id": .string("thread-1"), "status": .object(["type": .string("idle")]),
        "turns": .array([.object(["id": .string("turn-1"), "status": .string("inProgress"), "items": .array([
            .object(["id": .string("message"), "type": .string("agentMessage"), "text": .string("Stale")])])])])])
    var conversation = CodexConversation()
    var streamed = false
    manager.onEvent = { _, method, params in
        conversation.receive(method: method, params: params, threadID: "thread-1")
        streamed = true
    }
    manager.onChange = { _, state in if state.connection == .connecting { conversation.beginHydration() } }
    manager.onHydrate = { id, thread in
        #expect(manager.states[id]?.thread == nil)
        conversation.hydrate(thread: thread, threadID: "thread-1")
    }
    server.beforeResponse = { method in
        if method == "thread/resume" {
            server.emit("item/agentMessage/delta", id: "thread-1", fields: [
                "turnId": .string("turn-1"), "itemId": .string("message"), "delta": .string("Newest")])
            try? await eventually { streamed }
        }
    }
    try await manager.select(sessionID: "session")
    #expect(manager.states["session"]?.thread == nil)
    #expect(conversation.turns[0].items[0].text == "Newest")
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

@Test @MainActor func codexFallbackRejectsUncertainCreationAndBusySiblingThreads() async throws {
    let server = ThreadServer()
    let manager = try coordinator(server)
    server.failures["thread/start"] = .timedOut("thread/start")
    do { try await manager.connect(sessionID: "session") } catch {}
    do {
        _ = try await manager.prepareForCLIFallback(sessionID: "session")
        Issue.record("Uncertain creation must retain its identity for recovery")
    } catch { #expect(error.localizedDescription.contains("Recover its stored thread ID")) }
    #expect(server.handoffs == 0)

    let server2 = ThreadServer()
    let manager2 = try coordinator(server2)
    try await manager2.select(sessionID: "session")
    try manager2.register(sessionID: "other", binding: .init(cwd: "/tmp/other"))
    try await manager2.connect(sessionID: "other")
    server2.emit("thread/status/changed", id: "thread-2", fields: ["status": .object([
        "type": .string("active"), "activeFlags": .array([.string("waitingOnApproval")])])])
    try await eventually { manager2.states["other"]?.needsAttention == true }
    do {
        _ = try await manager2.prepareForCLIFallback(sessionID: "session")
        Issue.record("Shared server cannot be stopped while another thread needs attention")
    } catch { #expect(error.localizedDescription.contains("Finish active native")) }
    #expect(server2.handoffs == 0)
    #expect(manager2.states["session"]?.binding.threadID == "thread-1")
}

@Test @MainActor func codexFallbackReapsServerAndCannotBeReattachedByStaleSelection() async throws {
    let server = ThreadServer()
    let manager = try coordinator(server)
    try await manager.select(sessionID: "session")
    let before = try #require(manager.states["session"]?.binding)
    let handedOff = try await manager.prepareForCLIFallback(sessionID: "session")
    #expect(handedOff == before)
    #expect(server.handoffs == 1)
    #expect(manager.states["session"]?.isSubscribed == false)
    do { try await manager.select(sessionID: "session") } catch {}
    #expect(server.count("thread/resume") == 0)
    #expect(server.starts == 1)
}

@Test @MainActor func codexDisableReleasesSelectedIdleThreadAndReenableResumesSameIdentity() async throws {
    let server = ThreadServer()
    let manager = try coordinator(server)
    try await manager.select(sessionID: "session")
    let original = try #require(manager.states["session"]?.binding)
    manager.isEnabled = false
    try await manager.synchronizeRollout()
    #expect(manager.selectedSessionID == "session")
    #expect(manager.states["session"]?.isSubscribed == false)
    #expect(server.count("thread/unsubscribe") == 1)
    #expect(server.handoffs == 1)
    await #expect(throws: CodexAppServerError.self) { try await manager.connect(sessionID: "session") }
    await #expect(throws: CodexAppServerError.self) { try await manager.startTurn(sessionID: "session", input: []) }
    await #expect(throws: CodexAppServerError.self) { try await manager.read(sessionID: "session") }
    await #expect(throws: CodexAppServerError.self) { try await manager.list() }
    #expect(server.count("turn/start") == 0)
    #expect(server.count("thread/resume") == 0)
    manager.isEnabled = true
    try await manager.synchronizeRollout()
    #expect(manager.states["session"]?.binding == original)
    #expect(manager.states["session"]?.isSubscribed == true)
    #expect(server.count("thread/resume") == 1)
    #expect(server.starts == 1)
}

@Test @MainActor func codexDisableKeepsBusySiblingAndPendingRepliesActionableUntilCompletion() async throws {
    let server = ThreadServer()
    let manager = try coordinator(server)
    try await manager.select(sessionID: "session")
    try manager.register(sessionID: "busy", binding: .init(cwd: "/tmp/other"))
    _ = try await manager.startTurn(sessionID: "busy", input: [])
    let handler = try #require(server.handler)
    let request = CodexServerRequest(id: .string("approval"), method: "item/commandExecution/requestApproval",
        params: .object(["threadId": .string("thread-2"), "turnId": .string("turn-1")]))
    let answer = Task { await handler(request) }
    try await eventually { manager.states["busy"]?.needsAttention == true }
    manager.isEnabled = false
    try await manager.synchronizeRollout()
    #expect(manager.states["session"]?.isSubscribed == false)
    #expect(manager.states["busy"]?.isSubscribed == true)
    #expect(server.handoffs == 0)
    #expect(server.count("turn/interrupt") == 0)
    _ = try await manager.read(sessionID: "busy")
    await #expect(throws: CodexAppServerError.self) { try await manager.interrupt(sessionID: "busy", expectedTurnID: "old-turn") }
    #expect(server.count("turn/interrupt") == 0)
    try await manager.interrupt(sessionID: "busy", expectedTurnID: "turn-1")
    #expect(server.count("turn/interrupt") == 1) // Explicit user interrupt remains available.
    #expect(server.connectedRequests.contains("turn/interrupt"))
    try manager.respond(sessionID: "busy", requestID: request.id, reply: .result(.object(["decision": .string("accept")])))
    if case .result = await answer.value {} else { Issue.record("Existing pending reply must remain actionable") }
    #expect(manager.states["busy"]?.needsAttention == true)
    // Even selected busy work releases after completing while native is disabled.
    try await manager.select(sessionID: "busy")
    server.emit("turn/completed", id: "thread-2", fields: ["turn": .object(["id": .string("turn-1"), "status": .string("completed")])])
    try await eventually { server.handoffs == 1 }
    #expect(manager.states["busy"]?.isSubscribed == false)
    #expect(server.count("thread/start") == 2)
    #expect(server.count("thread/resume") == 0)
    manager.isEnabled = true
    try await manager.synchronizeRollout()
    #expect(manager.states["busy"]?.binding.threadID == "thread-2")
    #expect(server.count("thread/resume") == 1)
}

@Test @MainActor func codexDisableReobservesATurnThatStartsDuringIdleUnsubscribe() async throws {
    let server = ThreadServer()
    let manager = try coordinator(server)
    try await manager.select(sessionID: "session")
    server.beforeResponse = { method in
        if method == "thread/unsubscribe" {
            server.emit("thread/status/changed", id: "thread-1", fields: ["status": .object([
                "type": .string("active"), "activeFlags": .array([.string("waitingOnApproval")])])])
            try? await eventually { manager.states["session"]?.needsAttention == true }
        }
    }
    manager.isEnabled = false
    try await manager.synchronizeRollout()
    #expect(manager.states["session"]?.isSubscribed == true)
    #expect(manager.states["session"]?.needsAttention == true)
    #expect(server.handoffs == 0)
    #expect(server.count("thread/resume") == 1)
    #expect(server.count("turn/interrupt") == 0)
}

@Test @MainActor func codexOldBindingsLearnEffectiveStorageHomeAndRefuseAChangedNativeStore() async throws {
    let server = ThreadServer()
    server.effectiveHome = "/tmp/resolved-shell-store"
    server.threads["original"] = .object(["id": .string("original"), "status": .object(["type": .string("idle")])])
    let manager = try coordinator(server, threadID: "original")
    try await manager.connect(sessionID: "session")
    #expect(manager.states["session"]?.binding.codexHome == server.effectiveHome)
    server.effectiveHome = "/tmp/another-store"
    await #expect(throws: CodexAppServerError.self) { try await manager.connect(sessionID: "session") }
    #expect(server.count("thread/resume") == 1)
    let handedOff = try await manager.prepareForCLIFallback(sessionID: "session")
    #expect(handedOff.codexHome == "/tmp/resolved-shell-store")
    #expect(try CodexCLIFallback.command(binding: handedOff).contains("'CODEX_HOME=/tmp/resolved-shell-store'"))

    // Old rows must also gain shell-resolved provenance when disabled and
    // falling back without ever starting the native server.
    let old = try coordinator(server, id: "old", threadID: "stored-old")
    old.isEnabled = false
    let fallback = try await old.prepareForCLIFallback(sessionID: "old")
    #expect(fallback.codexHome == "/tmp/another-store")
}

@Test @MainActor func codexDisableDuringResumeCannotStartANewTurn() async throws {
    let server = ThreadServer()
    let manager = try coordinator(server)
    try await manager.connect(sessionID: "session")
    server.beforeResponse = { method in
        if method == "thread/resume" { manager.isEnabled = false }
    }
    await #expect(throws: CodexAppServerError.self) { try await manager.startTurn(sessionID: "session", input: []) }
    #expect(server.count("turn/start") == 0)
    try await manager.synchronizeRollout()
    #expect(manager.states["session"]?.isSubscribed == false)
}

@Test @MainActor func codexDisableDuringPreflightReapsAnUnclaimedServerWithoutCreatingARow() async throws {
    let server = ThreadServer()
    let manager = CodexThreadCoordinator(service: server)
    server.onConnect = { manager.isEnabled = false }
    await #expect(throws: CodexAppServerError.self) { try await manager.preflight() }
    try await manager.synchronizeRollout()
    #expect(manager.states.isEmpty)
    #expect(server.starts == 0)
    #expect(server.handoffs == 1)
}

@Test @MainActor func nativeAgentAdmissionBoundsParallelTurnsWithinOneServer() async throws {
    let server = ThreadServer()
    let pool = AgentAdmissionController(limit: 2)
    let manager = CodexThreadCoordinator(service: server, admission: pool)
    for id in ["a", "b", "c"] {
        try manager.register(sessionID: id, binding: .init(cwd: "/tmp/project"))
        try await manager.connect(sessionID: id)
    }
    #expect(server.starts == 3)
    #expect(pool.running.isEmpty) // Idle native threads do not claim CPU-turn slots.
    _ = try await manager.startTurn(sessionID: "a", input: [])
    _ = try await manager.startTurn(sessionID: "b", input: [])
    let third = Task { try await manager.startTurn(sessionID: "c", input: []) }
    try await admissionEventually { pool.queuedIDs == ["c"] }
    #expect(server.count("turn/start") == 2)
    try await manager.interrupt(sessionID: "a")
    #expect(pool.running == ["a", "b"]) // An interrupt ACK is not a completion.
    server.emit("turn/completed", id: "thread-1", fields: ["turn": .object([
        "id": .string("turn-1"), "status": .string("interrupted")])])
    _ = try await third.value
    #expect(server.count("turn/start") == 3)
    #expect(pool.running == ["b", "c"])
}

@Test @MainActor func nativeAgentAdmissionQueuesCreationResumeAndRecoveryWithoutChangingBindings() async throws {
    let server = ThreadServer()
    let pool = AgentAdmissionController(limit: 1)
    let manager = CodexThreadCoordinator(service: server, admission: pool)
    pool.adopt("terminal")
    let binding = CodexThreadBinding(cwd: "/tmp/project", settings: .init(model: "fixture-model", approvalPolicy: "untrusted"))
    try manager.register(sessionID: "new", binding: binding)
    let create = Task { try await manager.connect(sessionID: "new") }
    try await admissionEventually { pool.queuedIDs == ["new"] }
    #expect(server.starts == 0)
    #expect(manager.states["new"]?.binding == binding)
    pool.cancel("new")
    await #expect(throws: CancellationError.self) { try await create.value }
    #expect(manager.states["new"]?.binding == binding)

    let mapped = CodexThreadBinding(threadID: "stored", cwd: "/tmp/project", settings: binding.settings)
    try manager.register(sessionID: "restored", binding: mapped)
    server.threads["stored"] = .object(["id": .string("stored"), "cwd": .string("/tmp/project"),
        "status": .object(["type": .string("idle")])])
    let resume = Task { try await manager.connect(sessionID: "restored") }
    try await admissionEventually { pool.queuedIDs == ["restored"] }
    #expect(server.count("thread/resume") == 0)
    pool.cancel("restored")
    await #expect(throws: CancellationError.self) { try await resume.value }
    #expect(manager.states["restored"]?.binding == mapped)
    let recovery = Task { try await manager.recoverCreation(sessionID: "new", threadID: "stored") }
    try await admissionEventually { pool.queuedIDs == ["new"] }
    pool.cancel("new")
    await #expect(throws: CancellationError.self) { try await recovery.value }
    #expect(server.count("thread/read") == 0)
    #expect(manager.states["new"]?.binding == binding)
    pool.release("terminal")
}

@Test @MainActor func nativeAgentAdmissionPreservesRestoredBusyWorkAndPendingApprovals() async throws {
    let server = ThreadServer()
    let pool = AgentAdmissionController(limit: 1)
    let manager = CodexThreadCoordinator(service: server, admission: pool)
    for id in ["a", "b"] {
        let threadID = "stored-\(id)"
        server.threads[threadID] = .object(["id": .string(threadID),
            "status": .object(["type": .string("active")]),
            "turns": .array([.object(["id": .string("live-\(id)"), "status": .string("inProgress")])])])
        try manager.register(sessionID: id, binding: .init(threadID: threadID, cwd: "/tmp/project"))
        manager.adoptRestoredWork(sessionID: id)
    }
    try await manager.connect(sessionID: "a")
    try await manager.connect(sessionID: "b")
    #expect(pool.running == ["a", "b"])
    let handler = try #require(server.handler)
    let approval = Task { await handler(.init(id: .integer(42), method: "item/commandExecution/requestApproval",
        params: .object(["threadId": .string("stored-a"), "turnId": .string("live-a")]))) }
    try await admissionEventually { manager.states["a"]?.needsAttention == true }
    pool.cancel("a") // Cancellation only removes queued work, never a live ask.
    #expect(manager.states["a"]?.pendingRequests.count == 1)
    try manager.respond(sessionID: "a", requestID: .integer(42), reply: .result(.object(["decision": .string("decline")])))
    _ = await approval.value
    #expect(pool.running == ["a", "b"])
    server.emit("turn/completed", id: "stored-a", fields: ["turn": .object([
        "id": .string("live-a"), "status": .string("completed")])])
    try await admissionEventually { pool.running == ["b"] }
}

@Test @MainActor func nativeAgentAdmissionReleasesDefiniteFailureButKeepsUncertainStarts() async throws {
    let server = ThreadServer()
    let pool = AgentAdmissionController(limit: 1)
    let manager = CodexThreadCoordinator(service: server, admission: pool)
    try manager.register(sessionID: "a", binding: .init(cwd: "/tmp/project"))
    try await manager.connect(sessionID: "a")
    server.failures["turn/start"] = .remote(code: -32602, message: "Invalid input")
    await #expect(throws: CodexAppServerError.self) { try await manager.startTurn(sessionID: "a", input: []) }
    #expect(pool.running.isEmpty)
    server.failures["turn/start"] = .timedOut("turn/start")
    await #expect(throws: CodexAppServerError.self) { try await manager.startTurn(sessionID: "a", input: []) }
    #expect(pool.running == ["a"])
    server.failures.removeValue(forKey: "turn/start")
    try await manager.connect(sessionID: "a")
    #expect(pool.running.isEmpty)
}

@Test @MainActor func nativeAgentAdmissionCancellationImmediatelyAfterGrantReleasesUnusedReservation() async throws {
    let server = ThreadServer()
    let pool = AgentAdmissionController(limit: 1)
    let manager = CodexThreadCoordinator(service: server, admission: pool)
    try manager.register(sessionID: "new", binding: .init(cwd: "/tmp/project"))
    pool.adopt("busy")
    let queued = Task { try await manager.startTurn(sessionID: "new", input: []) }
    try await admissionEventually { pool.queuedIDs == ["new"] }
    pool.onChange = {
        if pool.running.contains("new") { queued.cancel() }
    }
    pool.release("busy")
    await #expect(throws: CancellationError.self) { try await queued.value }
    #expect(pool.running.isEmpty)
    #expect(server.starts == 0 && server.count("turn/start") == 0)
}

@Test @MainActor func nativeAgentAdmissionKeepsLostCreationResumeAndUnknownRepliesReserved() async throws {
    let server = ThreadServer()
    let pool = AgentAdmissionController(limit: 1)
    let manager = CodexThreadCoordinator(service: server, admission: pool)
    try manager.register(sessionID: "uncertain", binding: .init(cwd: "/tmp/project"))
    server.failures["thread/start"] = .timedOut("thread/start")
    await #expect(throws: CodexAppServerError.self) { try await manager.connect(sessionID: "uncertain") }
    #expect(pool.running == ["uncertain"])
    #expect(manager.states["uncertain"]?.binding.creationAttempted == true)
    server.failures.removeAll()
    server.threads["stored"] = .object(["id": .string("stored"), "cwd": .string("/tmp/project"),
        "status": .object(["type": .string("unknown")])])
    try await manager.recoverCreation(sessionID: "uncertain", threadID: "stored")
    #expect(pool.running == ["uncertain"])
    server.emit("thread/status/changed", id: "stored", fields: ["status": .object(["type": .string("idle")])])
    // Slot release precedes the asynchronous idle unsubscribe. A connect while
    // still subscribed correctly does nothing, so wait for confirmed teardown
    // before testing a lost resume reply.
    try await admissionEventually {
        pool.running.isEmpty && manager.states["uncertain"]?.isSubscribed == false &&
            manager.states["uncertain"]?.connection == .unsubscribed
    }
    let resumes = server.count("thread/resume")
    server.failures["thread/resume"] = .timedOut("thread/resume")
    await #expect(throws: CodexAppServerError.self) { try await manager.connect(sessionID: "uncertain") }
    #expect(server.count("thread/resume") == resumes + 1)
    #expect(pool.running == ["uncertain"])
}

@Test @MainActor func nativeAgentAdmissionCancellationWhileWaitingForLifecycleLockDoesNotStartWork() async throws {
    let server = ThreadServer()
    let pool = AgentAdmissionController(limit: 2)
    let manager = CodexThreadCoordinator(service: server, admission: pool)
    for id in ["first", "cancelled"] { try manager.register(sessionID: id, binding: .init(cwd: "/tmp/project")) }
    var gate: CheckedContinuation<Void, Never>?
    server.beforeResponse = { method in
        if method == "thread/start", server.count(method) == 1 {
            await withCheckedContinuation { gate = $0 }
        }
    }
    let first = Task { try await manager.connect(sessionID: "first") }
    try await admissionEventually { gate != nil }
    let cancelled = Task { try await manager.connect(sessionID: "cancelled") }
    try await admissionEventually { pool.running == ["first", "cancelled"] }
    cancelled.cancel()
    gate?.resume()
    try await first.value
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    #expect(server.starts == 1 && pool.running.isEmpty)
    #expect(manager.states["cancelled"]?.binding.creationAttempted == false)
}

@Test @MainActor func nativeAgentAdmissionCannotMutateCLIOwnershipAfterFallback() async throws {
    let server = ThreadServer()
    let pool = AgentAdmissionController(limit: 1)
    let manager = CodexThreadCoordinator(service: server, admission: pool)
    try manager.register(sessionID: "same-id", binding: .init(cwd: "/tmp", settings: .init(model: "synthetic-model")))
    try await manager.select(sessionID: "same-id")
    let original = try #require(manager.states["same-id"]?.binding)
    var oldSelection: Task<Void, Error>?
    server.duringFallbackValidation = {
        // This admission predates transfer but its operation/defer is blocked
        // by fallback's lifecycle lock until the terminal owns the same ID.
        oldSelection = Task { try await manager.connect(sessionID: "same-id") }
        try? await admissionEventually { pool.running.contains("same-id") }
    }
    let handedOff = try await manager.prepareForCLIFallback(sessionID: "same-id")
    #expect(handedOff == original && pool.running.isEmpty)
    #expect(pool.request("same-id", start: {})) // The terminal now owns it.
    if let oldSelection { await #expect(throws: (any Error).self) { try await oldSelection.value } }
    #expect(pool.running == ["same-id"])
    server.emit("thread/status/changed", id: "thread-1", fields: ["status": .object(["type": .string("idle")])])
    server.emit("turn/completed", id: "thread-1", fields: ["turn": .object(["id": .string("old"), "status": .string("completed")])])
    server.disconnect()
    for _ in 0..<20 { await Task.yield() }
    #expect(pool.running == ["same-id"])
    pool.release("same-id")
    server.emit("thread/status/changed", id: "thread-1", fields: ["status": .object(["type": .string("active")])])
    for _ in 0..<20 { await Task.yield() }
    #expect(pool.running.isEmpty)
    await #expect(throws: (any Error).self) { try await manager.connect(sessionID: "same-id") }
    #expect(pool.running.isEmpty && pool.queuedIDs.isEmpty)
    #expect(manager.states["same-id"]?.binding == original)
}
