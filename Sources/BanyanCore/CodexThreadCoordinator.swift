import Foundation

public struct CodexThreadState: Sendable {
    public var binding: CodexThreadBinding
    public var connection: CodexThreadConnection = .disconnected
    public var runtime = CodexThreadRuntime()
    public var activeTurnID: String?
    public var lastTurnStatus: String?
    public var pendingRequests: [CodexServerRequest] = []
    public var isSubscribed = false
    public var thread: CodexJSONValue?
    fileprivate var revision = 0

    public var needsAttention: Bool {
        !pendingRequests.isEmpty || runtime.activeFlags.contains("waitingOnApproval")
            || runtime.activeFlags.contains("waitingOnUserInput")
    }

    public var canReleaseSubscription: Bool {
        isSubscribed && runtime.type == "idle" && activeTurnID == nil && !needsAttention
    }
}

/// The session layer owns subscription lifetime; the transport owns the child.
/// All lifecycle RPCs are serialized across awaits. Notifications still apply
/// immediately, and revisions keep an older response from overwriting them.
@MainActor
public final class CodexThreadCoordinator {
    public private(set) var states: [String: CodexThreadState] = [:]
    public private(set) var selectedSessionID: String?
    public var onChange: ((String, CodexThreadState) -> Void)?
    /// Drain queued host writes before start and after learning thread identity.
    public var flushPersistence: (() async -> Void)?
    /// UI consumers hydrate with read() and then consume these streamed events.
    public var onEvent: ((String, String, CodexJSONValue) -> Void)?

    private let service: any CodexThreadService
    private var observation: Task<Void, Never>?
    private var setup: Task<Void, Never>?
    private var epoch = 0
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var replies: [String: CheckedContinuation<CodexServerReply, Never>] = [:]
    private var sessionIDByThreadID: [String: String] = [:]

    public init(service: any CodexThreadService) { self.service = service }

    deinit {
        observation?.cancel()
        for reply in replies.values {
            reply.resume(returning: .error(code: -32000, message: "Banyan disconnected"))
        }
    }

    public func register(sessionID: String, binding: CodexThreadBinding) throws {
        guard !sessionID.isEmpty, binding.cwd.hasPrefix("/"), !binding.cwd.contains("\0"),
              binding.threadID?.isEmpty != true else {
            throw CodexAppServerError.protocolViolation("Codex sessions need an absolute working directory and nonempty IDs")
        }
        if let existing = states[sessionID] {
            guard existing.binding == binding else {
                throw CodexAppServerError.protocolViolation("This Banyan ID is reserved for a different Codex thread or settings")
            }
            return
        }
        if let threadID = binding.threadID,
           sessionIDByThreadID[threadID] != nil {
            throw CodexAppServerError.protocolViolation("This Codex thread is already mapped to another Banyan session")
        }
        states[sessionID] = CodexThreadState(binding: binding)
        if let threadID = binding.threadID { sessionIDByThreadID[threadID] = sessionID }
    }

    /// Removed rows can still own busy work. Reserve their IDs for this app
    /// lifetime so a later spawn cannot inherit that work or its settings.
    public func reserves(sessionID: String) -> Bool { states[sessionID] != nil }

    /// Selection intent is recorded before waiting for any RPC. Rapid selection
    /// changes cannot leave a late-resumed idle thread subscribed in background.
    public func select(sessionID: String?) async throws {
        selectedSessionID = sessionID
        await ensureObservation()
        await acquire()
        defer { release() }
        var failure: Error?
        if let selected = selectedSessionID {
            do { try await attach(selected) } catch { failure = error }
        }
        for id in Array(states.keys) where id != selectedSessionID {
            do { try await releaseIdle(id) } catch { failure = failure ?? error }
        }
        if let failure { throw failure }
    }

    /// Used for explicit background creation and reconnect/retry. Never starts
    /// a new thread when a mapped thread cannot be resumed.
    public func connect(sessionID: String) async throws {
        await ensureObservation()
        await acquire()
        defer { release() }
        try await attach(sessionID)
        if selectedSessionID != sessionID { try await releaseIdle(sessionID) }
    }

    public func list(cursor: String? = nil, cwd: String? = nil) async throws -> CodexJSONValue {
        var params: [String: CodexJSONValue] = [:]
        if let cursor { params["cursor"] = .string(cursor) }
        if let cwd { params["cwd"] = .string(cwd) }
        return try await service.request("thread/list", params: .object(params))
    }

    /// Read is deliberately subscription-free, including during writer conflicts.
    public func read(sessionID: String, includeTurns: Bool = true) async throws -> CodexJSONValue {
        let threadID = try mappedID(sessionID)
        return try await service.request("thread/read", params: .object([
            "threadId": .string(threadID), "includeTurns": .bool(includeTurns)
        ]))
    }

    /// Resolve an uncertain start using an explicitly chosen stored thread.
    /// Existing mappings are immutable; this cannot replace a failed resume.
    public func recoverCreation(sessionID: String, threadID: String) async throws {
        await ensureObservation()
        await acquire()
        defer { release() }
        guard let state = states[sessionID], state.binding.threadID == nil,
              sessionIDByThreadID[threadID] == nil else {
            throw CodexAppServerError.protocolViolation("This session or thread already has a mapping")
        }
        let result = try await service.request("thread/read", params: .object(["threadId": .string(threadID)]))
        let thread = result.objectValue?["thread"]?.objectValue
        guard thread?["id"]?.stringValue == threadID, thread?["cwd"]?.stringValue == state.binding.cwd else {
            throw CodexAppServerError.protocolViolation("Choose a stored thread in this session's working directory")
        }
        update(sessionID) { $0.binding.threadID = threadID; $0.binding.creationAttempted = true }
        sessionIDByThreadID[threadID] = sessionID
        await flushPersistence?()
        try await attach(sessionID)
        if selectedSessionID != sessionID { try await releaseIdle(sessionID) }
    }

    public func startTurn(sessionID: String, input: [CodexJSONValue]) async throws -> CodexJSONValue {
        await ensureObservation()
        await acquire()
        defer { release() }
        try await attach(sessionID)
        guard let state = states[sessionID], !state.needsAttention,
              state.runtime.type == "idle", state.activeTurnID == nil else {
            throw CodexAppServerError.protocolViolation("Finish the active turn or answer the pending request first")
        }
        let current = epoch
        update(sessionID) { $0.runtime = .init(type: "active"); $0.lastTurnStatus = nil }
        do {
            let result = try await service.request("turn/start", params: .object([
                "threadId": .string(try mappedID(sessionID)), "input": .array(input)
            ]))
            try checkEpoch(current)
            // A fast turn may have completed before the RPC response arrived.
            if states[sessionID]?.runtime.type == "active" {
                update(sessionID) { $0.activeTurnID = result.objectValue?["turn"]?.objectValue?["id"]?.stringValue }
            }
            return result
        } catch {
            recordFailure(error, sessionID: sessionID)
            throw error
        }
    }

    public func interrupt(sessionID: String) async throws {
        guard let turnID = states[sessionID]?.activeTurnID else { return }
        _ = try await service.request("turn/interrupt", params: .object([
            "threadId": .string(try mappedID(sessionID)), "turnId": .string(turnID)
        ]))
    }

    public func respond(sessionID: String, requestID: CodexJSONValue, reply: CodexServerReply) throws {
        let threadID = try mappedID(sessionID)
        guard states[sessionID]?.pendingRequests.contains(where: { $0.id == requestID }) == true,
              let continuation = replies.removeValue(forKey: replyKey(threadID, requestID)) else {
            throw CodexAppServerError.protocolViolation("This Codex request is no longer pending; reconnect before answering")
        }
        // Keep the pending marker until serverRequest/resolved (or turn end).
        // Sending a reply alone does not prove the server has consumed it.
        continuation.resume(returning: reply)
    }

    /// Explicit handoff has the same safety rule as background selection. It
    /// releases a subscription; server unload/writer release happens later.
    public func detach(sessionID: String) async throws {
        await acquire()
        defer { release() }
        guard let state = states[sessionID], state.runtime.type != "active",
              state.activeTurnID == nil, !state.needsAttention else {
            throw CodexAppServerError.protocolViolation("Wait for the active turn and pending requests before detaching")
        }
        if selectedSessionID == sessionID { selectedSessionID = nil }
        try await releaseIdle(sessionID)
    }

    private func ensureObservation() async {
        if let setup { return await setup.value }
        guard observation == nil else { return }
        let service = service
        let task = Task { [weak self] in
            let stream = await service.events()
            await service.setServerRequestHandler { [weak self] request in
                guard let self else { return .error(code: -32000, message: "Banyan disconnected") }
                return await self.receive(request)
            }
            self?.observation = Task { [weak self] in
                for await event in stream {
                    guard !Task.isCancelled else { return }
                    self?.receive(event)
                }
                guard !Task.isCancelled else { return }
                self?.disconnected("Codex event stream ended. Reconnect to reload thread state.")
                self?.observation = nil
            }
        }
        setup = task
        await task.value
        setup = nil
    }

    private func attach(_ id: String) async throws {
        guard let state = states[id] else { throw CodexAppServerError.protocolViolation("Unknown Banyan Codex session") }
        if state.isSubscribed && state.connection == .subscribed { return }
        let current = epoch
        let revision = state.revision
        var params = state.binding.settings.parameters(cwd: state.binding.cwd)
        let method: String
        if let threadID = state.binding.threadID {
            method = "thread/resume"
            params["threadId"] = .string(threadID)
        } else {
            guard !state.binding.creationAttempted else {
                let message = "Codex thread creation was interrupted. List stored threads and reconnect to the existing ID before retrying."
                  update(id) { $0.connection = .unavailable(message) }
                throw CodexAppServerError.protocolViolation(message)
            }
            method = "thread/start"
            do {
                try await service.connect()
                try checkEpoch(current)
                try Task.checkCancellation()
            } catch {
                recordFailure(error, sessionID: id)
                throw error
            }
            // Persist this before sending: a timeout may still create a thread.
            update(id) { $0.binding.creationAttempted = true }
            await flushPersistence?()
        }
        update(id) { $0.connection = .connecting }
        do {
            let result = try await service.request(method, params: .object(params))
            try checkEpoch(current)
            guard let thread = result.objectValue?["thread"],
                  let threadID = thread.objectValue?["id"]?.stringValue, !threadID.isEmpty,
                  state.binding.threadID == nil || state.binding.threadID == threadID else {
                throw CodexAppServerError.protocolViolation("Codex returned an invalid or different thread ID")
            }
            update(id) {
                $0.binding.threadID = threadID
                if let model = result.objectValue?["model"]?.stringValue { $0.binding.settings.model = model }
                if let provider = result.objectValue?["modelProvider"]?.stringValue { $0.binding.settings.modelProvider = provider }
                $0.isSubscribed = true
                $0.connection = .subscribed
                $0.thread = thread
                if $0.revision == revision {
                    $0.runtime = CodexThreadRuntime(thread.objectValue?["status"])
                    $0.activeTurnID = nil
                    if case .array(let turns)? = thread.objectValue?["turns"] {
                        $0.activeTurnID = turns.last(where: {
                            $0.objectValue?["status"]?.stringValue == "inProgress"
                        })?.objectValue?["id"]?.stringValue
                    }
                }
            }
            sessionIDByThreadID[threadID] = id
            await flushPersistence?()
        } catch {
            recordFailure(error, sessionID: id)
            throw error
        }
    }

    private func releaseIdle(_ id: String) async throws {
        guard id != selectedSessionID, let state = states[id], state.canReleaseSubscription,
              let threadID = state.binding.threadID else { return }
        let current = epoch
        do {
            let result = try await service.request("thread/unsubscribe", params: .object(["threadId": .string(threadID)]))
            try checkEpoch(current)
            guard let status = result.objectValue?["status"]?.stringValue,
                  ["unsubscribed", "notSubscribed", "notLoaded"].contains(status) else {
                throw CodexAppServerError.protocolViolation("Unknown Codex unsubscribe result")
            }
            update(id) {
                $0.isSubscribed = false
                $0.connection = .unsubscribed
                $0.thread = nil
                if status == "notLoaded" { $0.runtime = .init(type: "notLoaded") }
            }
            // An external turn or selection can arrive while unsubscribe awaits.
            // Reattach immediately rather than hiding its work or approvals.
            if selectedSessionID == id || states[id]?.runtime.type == "active" || states[id]?.needsAttention == true {
                try await attach(id)
            }
        } catch {
            recordFailure(error, sessionID: id)
            throw error
        }
    }

    private func receive(_ event: CodexAppServerEvent) {
        switch event {
        case .disconnected(let error): disconnected(error.localizedDescription)
        case .notification(let method, let params):
            let object = params.objectValue
            guard let threadID = object?["threadId"]?.stringValue ?? object?["thread"]?.objectValue?["id"]?.stringValue,
                  let id = sessionIDByThreadID[threadID] else { return }
            let lifecycleChanged = ["thread/status/changed", "turn/started", "turn/completed", "serverRequest/resolved", "thread/closed"].contains(method)
            if lifecycleChanged {
                update(id) { state in
                    state.revision += 1
                    switch method {
                    case "thread/status/changed":
                        state.runtime = CodexThreadRuntime(object?["status"])
                        if state.runtime.type == "idle" { state.activeTurnID = nil }
                    case "turn/started":
                        state.runtime = .init(type: "active")
                        state.lastTurnStatus = nil
                        state.activeTurnID = object?["turn"]?.objectValue?["id"]?.stringValue
                    case "turn/completed":
                        state.lastTurnStatus = object?["turn"]?.objectValue?["status"]?.stringValue
                        state.activeTurnID = nil
                        state.runtime = .init(type: "idle")
                        state.pendingRequests = []
                    case "serverRequest/resolved":
                        state.pendingRequests.removeAll { $0.id == object?["requestId"] }
                    case "thread/closed":
                        state.isSubscribed = false
                        state.runtime = .init(type: "notLoaded")
                        state.connection = .unsubscribed
                        state.thread = nil
                    default: break
                    }
                }
            }
            if method == "turn/completed" { clearReplies(threadID: threadID) }
            if method == "serverRequest/resolved", let requestID = object?["requestId"] {
                replies.removeValue(forKey: replyKey(threadID, requestID))?.resume(
                    returning: .error(code: -32000, message: "Codex request was resolved by another client"))
            }
            if method == "thread/closed" { clearReplies(threadID: threadID) }
            onEvent?(id, method, params)
            if lifecycleChanged, id != selectedSessionID, states[id]?.canReleaseSubscription == true {
                Task { [weak self] in
                    guard let self else { return }
                    await self.acquire()
                    defer { self.release() }
                    try? await self.releaseIdle(id) // releaseIdle publishes errors.
                }
            }
        }
    }

    private func receive(_ request: CodexServerRequest) async -> CodexServerReply {
        guard let threadID = request.params.objectValue?["threadId"]?.stringValue,
              let id = sessionIDByThreadID[threadID] else {
            return .error(code: -32601, message: "No Banyan session owns this Codex request")
        }
        let key = replyKey(threadID, request.id)
        guard replies[key] == nil else { return .error(code: -32600, message: "Duplicate Codex request") }
        return await withCheckedContinuation { continuation in
            replies[key] = continuation
            update(id) {
                $0.revision += 1
                $0.pendingRequests.append(request)
                $0.runtime = .init(type: "active", activeFlags: ["waitingOnApproval"])
            }
        }
    }

    private func disconnected(_ message: String) {
        epoch += 1
        for id in Array(states.keys) {
            update(id) {
                $0.isSubscribed = false
                $0.connection = .failed(message)
                // Runtime is unknown, not hibernated: a turn may have been cut off.
                $0.runtime = .init()
                $0.pendingRequests = []
                $0.thread = nil
                $0.revision += 1
            }
        }
        for reply in replies.values { reply.resume(returning: .error(code: -32000, message: message)) }
        replies.removeAll()
    }

    private func recordFailure(_ error: Error, sessionID: String) {
        let message = error.localizedDescription
        let lower = message.lowercased()
        let connection: CodexThreadConnection
        if lower.contains("active writer") || lower.contains("already being controlled") {
            connection = .writerConflict("Another Codex client holds this thread's writer. Exit or detach its CLI/TUI, or finish its active turn, then reconnect here. The thread and working directory are preserved. Server: \(message)")
        } else if lower.contains("no rollout") || lower.contains("not found") || lower.contains("does not exist") {
            connection = .unavailable("This Codex thread has no resumable history or is unavailable. New threads may have no rollout until their first turn. Restore its history or choose an existing thread; Banyan will preserve this ID. Server: \(message)")
        } else { connection = .failed(message) }
        update(sessionID) { $0.connection = connection }
    }

    private func mappedID(_ id: String) throws -> String {
        guard let threadID = states[id]?.binding.threadID else {
            throw CodexAppServerError.protocolViolation("This Banyan session has no mapped Codex thread")
        }
        return threadID
    }

    private func update(_ id: String, _ mutation: (inout CodexThreadState) -> Void) {
        guard var state = states[id] else { return }
        mutation(&state)
        states[id] = state
        onChange?(id, state)
    }

    private func checkEpoch(_ current: Int) throws {
        guard current == epoch else { throw CodexAppServerError.disconnected("Thread operation crossed a server restart") }
    }

    private func replyKey(_ threadID: String, _ id: CodexJSONValue) -> String {
        let data = (try? JSONEncoder().encode(id)) ?? Data()
        return threadID + ":" + data.base64EncodedString()
    }

    private func clearReplies(threadID: String) {
        for key in Array(replies.keys) where key.hasPrefix(threadID + ":") {
            replies.removeValue(forKey: key)?.resume(returning: .error(code: -32000, message: "Codex turn ended"))
        }
    }

    private func acquire() async {
        if !locked { locked = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { locked = false }
        else { waiters.removeFirst().resume() }
    }
}
