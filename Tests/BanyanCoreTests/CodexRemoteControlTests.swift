import Foundation
import Testing
@testable import BanyanCore

@MainActor
final class RemoteFixtureServer: CodexThreadService {
    var calls: [(String, CodexJSONValue)] = []
    var handler: CodexAppServerClient.RequestHandler?
    var streams: [AsyncStream<CodexAppServerEvent>.Continuation] = []
    var beforeConnect: (() async -> Void)?
    func connect() async throws { await beforeConnect?() }
    var beforeResponse: ((String) async -> Void)?
    var failStart = false
    var nextTurn = 0
    var storedTurns: [CodexJSONValue] = []
    func events() async -> AsyncStream<CodexAppServerEvent> { AsyncStream { streams.append($0) } }
    func setServerRequestHandler(_ handler: CodexAppServerClient.RequestHandler?) async { self.handler = handler }
    func request(_ method: String, params: CodexJSONValue) async throws -> CodexJSONValue {
        calls.append((method, params))
        await beforeResponse?(method)
        switch method {
        case "thread/resume", "thread/read":
            return .object(["thread": .object(["id": params.objectValue!["threadId"]!,
                "status": .object(["type": .string("idle")]), "turns": .array(storedTurns)])])
        case "thread/unsubscribe": return .object(["status": .string("unsubscribed")])
        case "turn/start":
            if failStart { throw CodexAppServerError.disconnected("Lost response") }
            nextTurn += 1
            return .object(["turn": .object(["id": .string("turn-\(nextTurn)")])])
        case "turn/steer", "turn/interrupt": return .object([:])
        default: throw CodexRemoteError.invalid("Unexpected RPC \(method)")
        }
    }
    func emit(_ method: String, fields: [String: CodexJSONValue] = [:]) {
        var fields = fields; fields["threadId"] = .string("original")
        for stream in streams { stream.yield(.notification(method: method, params: .object(fields))) }
    }
    func count(_ method: String) -> Int { calls.filter { $0.0 == method }.count }
}

@MainActor
struct RemoteFixture {
    let server = RemoteFixtureServer()
    let admission = AgentAdmissionController(limit: 1)
    let coordinator: CodexThreadCoordinator
    var remote: CodexRemoteControl
    let root: URL
    let principal = CodexRemotePrincipal(workspace: "T_TEST", channel: "C_TEST", user: "U_TEST")
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("remote-\(UUID())")
        coordinator = CodexThreadCoordinator(service: server, admission: admission)
        try coordinator.register(sessionID: "native", binding: .init(threadID: "original", cwd: "/tmp/project"))
        try coordinator.register(sessionID: "other", binding: .init(threadID: "other-thread", cwd: "/tmp/other"))
        remote = CodexRemoteControl(coordinator: coordinator, file: root.appendingPathComponent("state.json"))
        remote.metadata = { ($0, "/tmp/project") }
    }
    func request(_ action: String, fields: [String: Any] = [:], bound: Bool = true) throws -> CodexRemoteRequest {
        var body: [String: Any] = ["action": action, "principal": ["workspace": principal.workspace,
            "channel": principal.channel, "user": principal.user]]
        if bound, let attachment = remote.attachments.first {
            body.merge(["sessionID": attachment.sessionID, "threadID": attachment.threadID,
                "attachmentID": attachment.id, "slackThread": attachment.slackThread]) { _, new in new }
        }
        body.merge(fields) { _, new in new }
        return try JSONDecoder().decode(CodexRemoteRequest.self, from: JSONSerialization.data(withJSONObject: body))
    }
    func attach() async throws {
        try remote.configure(.init(enabled: true, allowed: [principal]))
        _ = try await remote.handle(request("attach", fields: ["sessionID": "native", "threadID": "original", "slackThread": "100.1"]))
    }
    func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw CodexRemoteError.invalid("Timed out") }
            await Task.yield()
        }
    }
}

@Suite(.serialized) @MainActor
struct CodexRemoteControlTests {
    @Test func accessControlDefaultsOffAndEmptyOrWrongTupleDenyEveryReadAndAction() async throws {
        let f = try RemoteFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        for action in ["list", "events", "snapshot", "receipt", "queue", "attach", "respond", "sync"] {
            await #expect(throws: CodexRemoteError.self) { try await f.remote.handle(f.request(action)) }
        }
        try f.remote.configure(.init(enabled: true))
        await #expect(throws: CodexRemoteError.self) { try await f.remote.handle(f.request("list")) }
        try await f.attach()
        for field in ["workspace", "channel", "user"] {
            var r = try f.request("list")
            if field == "workspace" { r.principal.workspace = "OTHER" }
            if field == "channel" { r.principal.channel = "OTHER" }
            if field == "user" { r.principal.user = "OTHER" }
            await #expect(throws: CodexRemoteError.self) { try await f.remote.handle(r) }
        }
        let list = try await f.remote.handle(f.request("list"))
        #expect(list.objectValue?["sessions"]?.arrayValue.first?.objectValue?["sessionID"] == .string("native"))
        #expect(list.objectValue?["sessions"]?.arrayValue.first?.objectValue?["threadID"] == .string("original"))
        #expect(f.server.count("thread/start") == 0)
    }

    @Test func threadAttachmentPersistsAndMultiplexesObservationWithoutIdleAdmission() async throws {
        var f = try RemoteFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var desktopChanges = 0, desktopEvents = 0, desktopHydrations = 0
        f.coordinator.onChange = { _, _ in desktopChanges += 1 }
        f.coordinator.onEvent = { _, _, _ in desktopEvents += 1 }
        f.coordinator.onHydrate = { _, _ in desktopHydrations += 1 }
        try await f.attach()
        #expect(f.admission.running.isEmpty)
        let attachment = f.remote.attachments.first!
        try await f.coordinator.select(sessionID: "other")
        #expect(f.coordinator.states["native"]?.isSubscribed == true)
        #expect(f.admission.running.isEmpty)
        f.server.emit("item/completed", fields: ["turnId": .string("old"), "item": .object([
            "id": .string("message"), "type": .string("agentMessage"), "text": .string("Background progress")])])
        try await f.wait { desktopEvents > 0 }
        let snapshot = try await f.remote.handle(f.request("snapshot"))
        #expect(snapshot.inspectableText.contains("Background progress"))
        #expect(desktopChanges > 0 && desktopHydrations > 0)
        f.remote = CodexRemoteControl(coordinator: f.coordinator, file: f.root.appendingPathComponent("state.json"))
        f.remote.metadata = { ($0, "/tmp/project") }
        await f.remote.restoreObservation()
        #expect(f.remote.attachments == [attachment])
        #expect(f.server.count("thread/start") == 0)
        await #expect(throws: CodexAppServerError.self) { try await f.coordinator.prepareForCLIFallback(sessionID: "native") }
        try f.remote.detachLocally(sessionID: "native")
        try await f.wait { f.coordinator.states["native"]?.isSubscribed == false }
        #expect(f.coordinator.states["native"]?.binding.threadID == "original")
    }

    @Test func queuedFollowupWaitsForIdleWithoutRequestsAndDuplicateRestartsNeverResubmit() async throws {
        var f = try RemoteFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.attach()
        f.server.emit("turn/started", fields: ["turn": .object(["id": .string("busy")])])
        try await f.wait { f.coordinator.states["native"]?.activeTurnID == "busy" }
        let r = try f.request("queue", fields: ["operationID": "event-1", "text": "Follow up"])
        #expect(try await f.remote.handle(r).objectValue?["status"] == .string("queued"))
        _ = try await f.remote.handle(r)
        #expect(f.server.count("turn/start") == 0)
        f.server.emit("turn/completed", fields: ["turn": .object(["id": .string("busy"), "status": .string("completed")])])
        try await f.wait { f.server.count("turn/start") == 1 }
        try await f.wait { f.remote.desktopStatus(sessionID: "native")?.contains("needs reconciliation") == false }
        _ = try await f.remote.handle(r)
        f.remote = CodexRemoteControl(coordinator: f.coordinator, file: f.root.appendingPathComponent("state.json"))
        f.remote.metadata = { ($0, "/tmp/project") }
        _ = try await f.remote.handle(r)
        #expect(f.server.count("turn/start") == 1)
        #expect(f.server.calls.first { $0.0 == "turn/start" }?.1.objectValue?["threadId"] == .string("original"))
        var changed = r; changed.text = "Different"
        await #expect(throws: CodexRemoteError.self) { try await f.remote.handle(changed) }
    }

    @Test func pendingQuestionsAndApprovalsUseExactOfferedChoicesAndInvalidateElsewhere() async throws {
        let f = try RemoteFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.attach()
        let handler = try #require(f.server.handler)
        let request = CodexServerRequest(id: .integer(42), method: "item/tool/requestUserInput", params: .object([
            "threadId": .string("original"), "turnId": .string("asking"), "questions": .array([.object([
                "id": .string("q"), "question": .string("Choose"), "options": .array([.object(["label": .string("Alpha")])])])])]))
        let answer = Task { await handler(request) }
        try await f.wait { f.coordinator.states["native"]?.needsAttention == true }
        let queued = try f.request("queue", fields: ["operationID": "queued", "text": "After answer"])
        _ = try await f.remote.handle(queued)
        let r = try f.request("respond", fields: ["operationID": "answer", "turnID": "asking", "requestID": 42, "answers": ["q": "Alpha"]])
        _ = try await f.remote.handle(r)
        if case .result(let result) = await answer.value { #expect(result.inspectableText.contains("Alpha")) }
        else { Issue.record("Question failed") }
        #expect(f.server.count("turn/start") == 0) // Reply is not resolved until server confirms.
        _ = try await f.remote.handle(r) // Already submitted, no second reply.
        f.server.emit("serverRequest/resolved", fields: ["requestId": .integer(42)])
        f.server.emit("turn/completed", fields: ["turn": .object(["id": .string("asking"), "status": .string("completed")])])
        try await f.wait { f.server.count("turn/start") == 1 }
        var stale = r; stale.operationID = "stale"
        await #expect(throws: CodexRemoteError.self) { try await f.remote.handle(stale) }
        let approval = CodexServerRequest(id: .string("approval"), method: "item/commandExecution/requestApproval", params: .object([
            "threadId": .string("original"), "turnId": .string("turn-1"), "availableDecisions": .array([.string("decline")])]))
        let decision = Task { await handler(approval) }
        try await f.wait { f.coordinator.states["native"]?.pendingRequests.count == 1 }
        var approve = try f.request("respond", fields: ["operationID": "approval", "turnID": "turn-1", "requestID": "approval", "decision": "accept"])
        await #expect(throws: CodexAppServerError.self) { try await f.remote.handle(approve) }
        approve.decision = "decline"
        _ = try await f.remote.handle(approve)
        if case .result(let result) = await decision.value { #expect(result.objectValue?["decision"] == .string("decline")) }
        else { Issue.record("Approval failed") }
    }

    @Test func steerAndStopRefuseChangedTurnPreserveIdentityAndDeduplicate() async throws {
        let f = try RemoteFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.attach()
        let binding = f.coordinator.states["native"]?.binding
        f.server.emit("turn/started", fields: ["turn": .object(["id": .string("current")])])
        try await f.wait { f.coordinator.states["native"]?.activeTurnID == "current" }
        for action in ["steer", "stop"] {
            var r = try f.request(action, fields: ["operationID": action, "turnID": "old", "text": "Steer"])
            await #expect(throws: CodexRemoteError.self) { try await f.remote.handle(r) }
            r.turnID = "current"
            _ = try await f.remote.handle(r)
            _ = try await f.remote.handle(r)
        }
        #expect(f.server.count("turn/steer") == 1 && f.server.count("turn/interrupt") == 1)
        #expect(f.coordinator.states["native"]?.binding == binding)
        #expect(f.server.count("thread/start") == 0)
    }

    @Test func desktopAnsweredRequestRejectsSlackBeforeWriteAheadAndDoesNotBlockQueue() async throws {
        let f = try RemoteFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.attach()
        let request = CodexServerRequest(id: .integer(99), method: "item/fileChange/requestApproval", params: .object([
            "threadId": .string("original"), "turnId": .string("active")]))
        let handler = try #require(f.server.handler)
        let desktopReply = Task { await handler(request) }
        try await f.wait { f.coordinator.states["native"]?.needsAttention == true }
        _ = try await f.remote.handle(f.request("queue", fields: ["operationID": "after-desktop", "text": "Continue"]))
        try f.coordinator.respond(sessionID: "native", requestID: request.id,
            reply: CodexConversationRequest(request).approvalReply(.decline))
        _ = await desktopReply.value
        let stale = try f.request("respond", fields: ["operationID": "stale-click", "turnID": "active", "requestID": 99, "decision": "accept"])
        await #expect(throws: CodexRemoteError.self) { try await f.remote.handle(stale) }
        let receipt = try await f.remote.handle(f.request("receipt", fields: ["operationID": "stale-click"]))
        #expect(receipt.objectValue?["status"] == .string("absent"))
        f.server.emit("serverRequest/resolved", fields: ["requestId": .integer(99)])
        f.server.emit("turn/completed", fields: ["turn": .object(["id": .string("active"), "status": .string("completed")])])
        try await f.wait { f.server.count("turn/start") == 1 }
        #expect(f.remote.desktopStatus(sessionID: "native")?.contains("needs reconciliation") == false)
    }

    @Test func steeringQueuedInputConsumesItsQueueEntryAndCannotSteerItTwice() async throws {
        let f = try RemoteFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.attach()
        f.server.emit("turn/started", fields: ["turn": .object(["id": .string("active")])])
        try await f.wait { f.coordinator.states["native"]?.activeTurnID == "active" }
        _ = try await f.remote.handle(f.request("queue", fields: ["operationID": "queued", "text": "Change direction"]))
        let steer = try f.request("steer", fields: ["operationID": "steer", "queuedOperationID": "queued",
            "turnID": "active", "text": "Change direction"])
        _ = try await f.remote.handle(steer)
        _ = try await f.remote.handle(steer)
        var stale = steer; stale.operationID = "different-click"
        await #expect(throws: CodexRemoteError.self) { try await f.remote.handle(stale) }
        f.server.emit("turn/completed", fields: ["turn": .object(["id": .string("active"), "status": .string("completed")])])
        try await f.wait { f.coordinator.states["native"]?.activeTurnID == nil }
        #expect(f.server.count("turn/steer") == 1 && f.server.count("turn/start") == 0)
    }

    @Test func disableOrDetachWhileLifecycleLockHeldRejectsSteerAndStopBeforeRPC() async throws {
        for action in ["steer", "stop"] {
            let f = try RemoteFixture()
            defer { try? FileManager.default.removeItem(at: f.root) }
            try await f.attach()
            f.server.emit("turn/started", fields: ["turn": .object(["id": .string("active")])])
            try await f.wait { f.coordinator.states["native"]?.activeTurnID == "active" }
            f.admission.setLimit(2) // Disposable controller only; let the holder reach the lifecycle lock.
            var gate: CheckedContinuation<Void, Never>?
            f.server.beforeResponse = { method in
                if method == "thread/resume" { await withCheckedContinuation { gate = $0 } }
            }
            let holder = Task { try await f.coordinator.connect(sessionID: "other") }
            try await f.wait { gate != nil }
            let r = try f.request(action, fields: ["operationID": action, "turnID": "active", "text": "steer"])
            let pending = Task { try await f.remote.handle(r) }
            try await f.wait { f.remote.desktopStatus(sessionID: "native")?.contains("needs reconciliation") == true }
            if action == "steer" { try f.remote.configure(.init(enabled: false, allowed: [f.principal])) }
            else { try f.remote.detachLocally(sessionID: "native") }
            f.server.beforeResponse = nil
            gate?.resume()
            try await holder.value
            await #expect(throws: CodexRemoteError.self) { try await pending.value }
            #expect(f.server.count("turn/steer") == 0 && f.server.count("turn/interrupt") == 0)
        }
    }

    @Test func detachDuringAdmissionCannotRestoreAnOldAttachmentOrReturnContext() async throws {
        let f = try RemoteFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try f.remote.configure(.init(enabled: true, allowed: [f.principal]))
        await Task.yield()
        f.admission.adopt("busy")
        let attach = Task { try await f.remote.handle(f.request("attach", fields: ["sessionID": "native", "threadID": "original", "slackThread": "1.2"])) }
        try await f.wait { !f.remote.attachments.isEmpty && f.admission.queuedIDs.contains("native") }
        let restoring = Task { await f.remote.restoreObservation() }
        try f.remote.detachLocally(sessionID: "native")
        f.admission.release("busy")
        await #expect(throws: CodexRemoteError.self) { try await attach.value }
        await restoring.value
        #expect(f.remote.attachments.isEmpty)
        #expect(f.server.count("thread/resume") == 0)
        #expect(f.coordinator.states["native"]?.isSubscribed == false)
    }

    @Test func detachOrDisableDuringConnectCannotResumeOrReturnStaleContext() async throws {
        for disable in [true, false] {
            let f = try RemoteFixture()
            defer { try? FileManager.default.removeItem(at: f.root) }
            try f.remote.configure(.init(enabled: true, allowed: [f.principal]))
            await Task.yield()
            var gate: CheckedContinuation<Void, Never>?
            f.server.beforeConnect = { await withCheckedContinuation { gate = $0 } }
            let pending = Task { try await f.remote.handle(f.request("attach", fields: ["sessionID": "native", "threadID": "original", "slackThread": "1.1"])) }
            try await f.wait { gate != nil }
            if disable { try f.remote.configure(.init(enabled: false, allowed: [f.principal])) }
            else { try f.remote.detachLocally(sessionID: "native") }
            f.server.beforeConnect = nil
            gate?.resume()
            await #expect(throws: CodexRemoteError.self) { try await pending.value }
            #expect(f.server.count("thread/resume") == 0)
            #expect(f.coordinator.states["native"]?.isSubscribed == false)
        }
    }

    @Test func detachOrDisableDuringReconcileCannotRehydrateReleasedDesktopHistory() async throws {
        for disable in [false, true] {
            let f = try RemoteFixture()
            defer { try? FileManager.default.removeItem(at: f.root) }
            f.server.storedTurns = [.object(["id": .string("history"), "status": .string("completed"), "items": .array([
                .object(["id": .string("old"), "type": .string("agentMessage"), "text": .string("Stored history")])])])]
            var desktop = CodexConversation(), hydrations = 0
            f.coordinator.onHydrate = { id, thread in
                if id == "native" { desktop.hydrate(thread: thread, threadID: "original"); hydrations += 1 }
            }
            f.coordinator.onChange = { id, state in
                if id == "native", state.connection == .unsubscribed { desktop.releaseHistory() }
            }
            try await f.attach()
            #expect(!desktop.turns.isEmpty)
            var gate: CheckedContinuation<Void, Never>?
            f.server.beforeResponse = { method in
                if method == "thread/read" { await withCheckedContinuation { gate = $0 } }
            }
            let pending = Task { try await f.remote.handle(f.request("reconcile")) }
            try await f.wait { gate != nil }
            let before = hydrations
            if disable { try f.remote.configure(.init(enabled: false, allowed: [f.principal])) }
            else { try f.remote.detachLocally(sessionID: "native") }
            try await f.wait { f.coordinator.states["native"]?.connection == .unsubscribed }
            #expect(desktop.turns.isEmpty)
            gate?.resume()
            await #expect(throws: CodexRemoteError.self) { try await pending.value }
            #expect(hydrations == before && desktop.turns.isEmpty)
            #expect(f.coordinator.states["native"]?.connection == .unsubscribed)
        }
    }

    @Test func boundedCursorGapRequiresAuthoritativeSnapshotRefresh() async throws {
        let f = try RemoteFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.attach()
        let first = try await f.remote.handle(f.request("sync"))
        for index in 0..<300 {
            f.server.emit("item/completed", fields: ["turnId": .string("turn"), "item": .object([
                "id": .string("item-\(index)"), "type": .string("agentMessage"), "text": .string("Progress")])])
        }
        var routed = 0
        let observer = f.coordinator.observe(.init(event: { _, _, _ in routed += 1 }))
        defer { f.coordinator.removeObserver(observer) }
        try await f.wait { routed == 300 }
        let gap = try await f.remote.handle(f.request("events", fields: ["cursor": 0, "epoch": first.objectValue!["epoch"]!.stringValue!]))
        #expect(gap.objectValue?["refresh"] == .bool(true))
        #expect(gap.objectValue?["events"]?.arrayValue.count == 256)
        #expect(gap.objectValue?["sessions"]?.arrayValue.first?.objectValue?["threadID"] == .string("original"))
    }

    @Test func journalByteLimitPreservesReceiptsAndRefusesWorkBeforeSideEffects() async throws {
        var f = try RemoteFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        f.remote = CodexRemoteControl(coordinator: f.coordinator, file: f.root.appendingPathComponent("state.json"), maximumJournalBytes: 2048)
        f.remote.metadata = { ($0, "/tmp/project") }
        try await f.attach()
        let before = try Data(contentsOf: f.root.appendingPathComponent("state.json"))
        let oversized = try f.request("queue", fields: ["operationID": "too-big", "text": String(repeating: "x", count: 3000)])
        await #expect(throws: CodexRemoteError.self) { try await f.remote.handle(oversized) }
        #expect(try Data(contentsOf: f.root.appendingPathComponent("state.json")) == before)
        #expect(f.server.count("turn/start") == 0)
        let restored = CodexRemoteControl(coordinator: f.coordinator, file: f.root.appendingPathComponent("state.json"), maximumJournalBytes: 2048)
        #expect(restored.storageError == nil && restored.attachments == f.remote.attachments)
    }

    @Test func journalDirectoryFailureFencesAlreadyEnabledControl() async throws {
        let f = try RemoteFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.attach()
        let action = try f.request("queue", fields: ["operationID": "storage-failure", "text": "Must not submit"])
        try FileManager.default.removeItem(at: f.root)
        try Data("Fixture blocks directory creation".utf8).write(to: f.root)
        await #expect(throws: (any Error).self) { try await f.remote.handle(action) }
        #expect(f.remote.storageError != nil)
        await #expect(throws: CodexRemoteError.self) { try await f.remote.handle(f.request("list")) }
        #expect(f.server.count("turn/start") == 0)
    }

    @Test func disconnectAndCursorGapsRefreshWithoutRetryingUnknownSubmissionAndDisableStopsActions() async throws {
        var f = try RemoteFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.attach()
        f.server.failStart = true
        let r = try f.request("queue", fields: ["operationID": "unknown", "text": "May have reached runtime"])
        _ = try await f.remote.handle(r)
        try await f.wait { f.remote.desktopStatus(sessionID: "native")?.contains("needs reconciliation") == true }
        _ = try await f.remote.handle(r)
        let sync = try await f.remote.handle(f.request("sync"))
        #expect(sync.objectValue?["refresh"] == .bool(true))
        #expect(f.remote.isOnline)
        _ = try await f.remote.handle(f.request("offline"))
        #expect(!f.remote.isOnline)
        f.remote = CodexRemoteControl(coordinator: f.coordinator, file: f.root.appendingPathComponent("state.json"))
        f.remote.metadata = { ($0, "/tmp/project") }
        _ = try await f.remote.handle(r)
        await f.remote.restoreObservation()
        #expect(f.server.count("turn/start") == 1)
        #expect(f.remote.desktopStatus(sessionID: "native")?.contains("needs reconciliation") == true)
        try f.remote.configure(.init(enabled: false, allowed: [f.principal]))
        await #expect(throws: CodexRemoteError.self) { try await f.remote.handle(r) }
        await #expect(throws: CodexRemoteError.self) { try await f.remote.handle(f.request("events")) }
        #expect(!f.remote.isOnline)
        try f.remote.resolveLocally(workspace: f.principal.workspace, operationID: "unknown")
        try f.remote.configure(.init(enabled: true, allowed: [f.principal]))
        #expect(try await f.remote.handle(r).objectValue?["status"] == .string("acknowledged"))
        #expect(f.server.count("turn/start") == 1) // Explicit resolution never resends.
    }
}
