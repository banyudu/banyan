import Foundation

public struct CodexThreadState: Sendable {
    public var binding: CodexThreadBinding
    public var connection: CodexThreadConnection = .disconnected
    public var runtime = CodexThreadRuntime()
    public var activeTurnID: String?
    public var lastTurnStatus: String?
    public var pendingRequests: [CodexServerRequest] = []
    public var isSubscribed = false
    /// Compatibility accessor: hydration snapshots are transient, never retained
    /// in lifecycle state. Consumers receive them through onHydrate instead.
    public var thread: CodexJSONValue? { nil }
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
    public var isEnabled = true
    private var cliSessionIDs: Set<String> = []
    private var serverReleasedForDisable = false
    private var hasNativeConnection = false
    public var onChange: ((String, CodexThreadState) -> Void)?
    /// Drain queued host writes before start and after learning thread identity.
    public var flushPersistence: (() async -> Void)?
    /// The response is borrowed only for this callback; consumers retain a
    /// bounded presentation, never the full raw resume history.
    public var onHydrate: ((String, CodexJSONValue) -> Void)?
    /// Streamed events may arrive during resume, before its hydration callback.
    public var onEvent: ((String, String, CodexJSONValue) -> Void)?

    public struct Observer {
        public var change: ((String, CodexThreadState) -> Void)?
        public var hydrate: ((String, CodexJSONValue) -> Void)?
        public var event: ((String, String, CodexJSONValue) -> Void)?
        public init(change: ((String, CodexThreadState) -> Void)? = nil,
                    hydrate: ((String, CodexJSONValue) -> Void)? = nil,
                    event: ((String, String, CodexJSONValue) -> Void)? = nil) {
            self.change = change; self.hydrate = hydrate; self.event = event
        }
    }
    private var observers: [UUID: Observer] = [:]
    private var remoteObservation: [String: Set<String>] = [:]

    @discardableResult public func observe(_ observer: Observer) -> UUID {
        let id = UUID(); observers[id] = observer; return id
    }
    public func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }

    /// Observation owns no idle admission reservation. Connect/start still pass
    /// through the shared admission controller and CLI ownership checks.
    public func setRemoteObservation(sessionID: String, ownerID: String, retained: Bool) {
        if retained { remoteObservation[sessionID, default: []].insert(ownerID) }
        else {
            remoteObservation[sessionID]?.remove(ownerID)
            if remoteObservation[sessionID]?.isEmpty == true { remoteObservation.removeValue(forKey: sessionID) }
        }
    }

    public func retainRemoteObservation(sessionID: String, retained: Bool, ownerID: String = "remote",
                                        authorization: (() throws -> Void)? = nil) async throws {
        if retained {
            guard states[sessionID]?.binding.threadID != nil, !cliSessionIDs.contains(sessionID) else {
                throw CodexAppServerError.protocolViolation("Remote control requires an existing native thread")
            }
            try authorization?()
            setRemoteObservation(sessionID: sessionID, ownerID: ownerID, retained: true)
            try await connect(sessionID: sessionID, authorization: authorization)
        } else {
            setRemoteObservation(sessionID: sessionID, ownerID: ownerID, retained: false)
            await acquire()
            defer { release() }
            try await releaseIdle(sessionID)
        }
    }

    private func publishEvent(_ id: String, _ method: String, _ params: CodexJSONValue) {
        onEvent?(id, method, params)
        for observer in Array(observers.values) { observer.event?(id, method, params) }
    }

    private let service: any CodexThreadService
    public let admission: AgentAdmissionController?
    private var admissionOperations: [String: Int] = [:]
    private var unresolvedWork: Set<String> = []
    private var observation: Task<Void, Never>?
    private var setup: Task<Void, Never>?
    private var epoch = 0
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var replies: [String: CheckedContinuation<CodexServerReply, Never>] = [:]
    private var sessionIDByThreadID: [String: String] = [:]

    public init(service: any CodexThreadService, admission: AgentAdmissionController? = nil) {
        self.service = service
        self.admission = admission
    }

    public func adoptRestoredWork(sessionID: String) {
        guard !cliSessionIDs.contains(sessionID) else { return }
        unresolvedWork.insert(sessionID)
        admission?.adopt(sessionID)
    }

    private func admitted<T>(_ id: String, operation: () async throws -> T) async throws -> T {
        guard !cliSessionIDs.contains(id) else { throw CodexAppServerError.protocolViolation("This session is owned by the CLI") }
        admissionOperations[id, default: 0] += 1
        defer {
            admissionOperations[id, default: 1] -= 1
            reconcileAdmission(id)
        }
        try await admission?.acquire(id)
        try Task.checkCancellation()
        guard !cliSessionIDs.contains(id) else { throw CodexAppServerError.protocolViolation("This session is owned by the CLI") }
        return try await operation()
    }

    private func reconcileAdmission(_ id: String) {
        guard !cliSessionIDs.contains(id) else { return }
        guard let state = states[id] else { admission?.release(id); return }
        if state.runtime.type == "active" || state.activeTurnID != nil || state.needsAttention || unresolvedWork.contains(id) {
            if admission?.running.contains(id) != true { admission?.adopt(id) }
        } else if admissionOperations[id, default: 0] == 0 {
            admission?.release(id)
        }
    }

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

    public func discardUnstartedSession(sessionID: String) {
        guard let state = states[sessionID], !state.binding.creationAttempted,
              state.binding.threadID == nil, !state.isSubscribed else { return }
        states.removeValue(forKey: sessionID)
        if selectedSessionID == sessionID { selectedSessionID = nil }
    }

    /// The gate changes synchronously; reconcile under the same lifecycle lock
    /// as connect/turn/fallback. Selection intent survives disable/re-enable.
    public func synchronizeRollout() async throws {
        if isEnabled, let id = selectedSessionID {
            try await admitted(id) { try await synchronizeRolloutAdmitted() }
        } else { try await synchronizeRolloutAdmitted() }
    }

    private func synchronizeRolloutAdmitted() async throws {
        await acquire()
        defer { release() }
        if isEnabled {
            serverReleasedForDisable = false
            if let selectedSessionID, admission == nil || admission?.running.contains(selectedSessionID) == true {
                try await attach(selectedSessionID)
            }
        }
        var failure: Error?
        for id in Array(states.keys) {
            do { try await releaseIdle(id) } catch { failure = failure ?? error }
        }
        // Even an unavailable unsubscribe capability can be handled by reaping
        // an entirely idle server; busy sibling work must stay connected.
        if try await finishDisableIfIdle() { return }
        if let failure { throw failure }
    }

    @discardableResult
    private func finishDisableIfIdle() async throws -> Bool {
        guard !isEnabled, !serverReleasedForDisable, (hasNativeConnection || !states.isEmpty),
              states.values.allSatisfy({
                  $0.runtime.type != "active" && $0.activeTurnID == nil && !$0.needsAttention
                      && (!$0.isSubscribed || $0.runtime.type == "idle")
              }) else { return false }
        try await service.disconnectForHandoff()
        disconnected("Native Codex is disabled. Enable it in Preferences to reconnect, or use Codex CLI.")
        for id in Array(states.keys) {
            update(id) { $0.connection = .unsubscribed; $0.runtime = .init(type: "notLoaded") }
        }
        serverReleasedForDisable = true
        return true
    }

    /// Probe startup before inserting a Banyan row. A rejected version cannot
    /// leave a partial session. Recheck the gate after the asynchronous probe.
    public func preflight() async throws -> String? {
        await acquire()
        defer { release() }
        try checkEnabled()
        try await service.connect()
        hasNativeConnection = true
        try checkEnabled()
        let home = await service.storageHome()
        try checkEnabled()
        return home
    }

    /// The shared server owns writers beyond unsubscribe's grace period. Reap
    /// it before launching the CLI, only when every native thread is safe.
    /// Keep mappings reserved so an in-flight selection cannot restart a thread.
    public func prepareForCLIFallback(sessionID: String) async throws -> CodexThreadBinding {
        await acquire()
        defer { release() }
        guard var state = states[sessionID] else {
            throw CodexAppServerError.protocolViolation("Unknown Banyan Codex session")
        }
        if state.binding.codexHome == nil {
            guard let home = await service.storageHome() else {
                throw CodexAppServerError.protocolViolation("Cannot determine this thread's Codex storage location. Reconnect once to record it before CLI fallback.")
            }
            state.binding.codexHome = home
            update(sessionID) { $0.binding.codexHome = state.binding.codexHome }
            await flushPersistence?()
        }
        _ = try CodexCLIFallback.command(binding: state.binding)
        try checkCLIHandoffIdle()
        let current = epoch
        try await service.validateCLIFallback(binding: state.binding)
        try checkEpoch(current)
        // Notifications still apply while CLI config loads. Never reap work
        // or approvals that arrived during this new asynchronous boundary.
        try checkCLIHandoffIdle()
        try await service.disconnectForHandoff()
        disconnected("Codex server released for CLI fallback. Reconnect native sessions when needed.")
        unresolvedWork.remove(sessionID)
        cliSessionIDs.insert(sessionID)
        admission?.cancel(sessionID)
        admission?.release(sessionID)
        if selectedSessionID == sessionID { selectedSessionID = nil }
        return state.binding
    }

    private func checkCLIHandoffIdle() throws {
        guard remoteObservation.isEmpty else {
            throw CodexAppServerError.protocolViolation("Detach Slack sessions before switching to the CLI")
        }
        guard states.values.allSatisfy({
            $0.runtime.type != "active" && $0.activeTurnID == nil && !$0.needsAttention
                && (!$0.isSubscribed || $0.runtime.type == "idle")
        }) else {
            throw CodexAppServerError.protocolViolation("Finish active native Codex turns and pending requests before switching to the CLI")
        }
    }

    private func checkEnabled() throws {
        guard isEnabled else {
            throw CodexAppServerError.protocolViolation("Native Codex is disabled. Enable it in Preferences or use the Codex CLI runtime.")
        }
    }

    /// Removed rows can still own busy work. Reserve their IDs for this app
    /// lifetime so a later spawn cannot inherit that work or its settings.
    public func reserves(sessionID: String) -> Bool { states[sessionID] != nil }

    /// Selection intent is recorded before waiting for any RPC. Rapid selection
    /// changes cannot leave a late-resumed idle thread subscribed in background.
    public func select(sessionID: String?) async throws {
        selectedSessionID = sessionID
        if isEnabled, let sessionID {
            try await admitted(sessionID) { try await selectAdmitted(sessionID: sessionID) }
        } else { try await selectAdmitted(sessionID: sessionID) }
    }

    private func selectAdmitted(sessionID: String?) async throws {
        await ensureObservation()
        await acquire()
        defer { release() }
        var failure: Error?
        if isEnabled, let selected = selectedSessionID, selected == sessionID {
            do { try await attach(selected) } catch { failure = error }
        }
        for id in Array(states.keys) where !isEnabled || id != selectedSessionID {
            do { try await releaseIdle(id) } catch { failure = failure ?? error }
        }
        if try await finishDisableIfIdle() { return }
        if let failure { throw failure }
    }

    /// Used for explicit background creation and reconnect/retry. Never starts
    /// a new thread when a mapped thread cannot be resumed.
    public func connect(sessionID: String, authorization: (() throws -> Void)? = nil) async throws {
        try await admitted(sessionID) { try await connectAdmitted(sessionID: sessionID, authorization: authorization) }
    }

    private func connectAdmitted(sessionID: String, authorization: (() throws -> Void)?) async throws {
        await ensureObservation()
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        try authorization?()
        try await attach(sessionID, authorization: authorization)
        try authorization?()
        if selectedSessionID != sessionID { try await releaseIdle(sessionID) }
    }

    public func list(cursor: String? = nil, cwd: String? = nil) async throws -> CodexJSONValue {
        try checkEnabled()
        var params: [String: CodexJSONValue] = [:]
        if let cursor { params["cursor"] = .string(cursor) }
        if let cwd { params["cwd"] = .string(cwd) }
        return try await service.request("thread/list", params: .object(params))
    }

    /// Read is deliberately subscription-free, including during writer conflicts.
    public func read(sessionID: String, includeTurns: Bool = true) async throws -> CodexJSONValue {
        let threadID = try mappedID(sessionID)
        let params: CodexJSONValue = .object(["threadId": .string(threadID), "includeTurns": .bool(includeTurns)])
        if !isEnabled {
            guard states[sessionID]?.isSubscribed == true else {
                throw CodexAppServerError.protocolViolation("Native Codex is disabled; this idle thread has been released. Enable it in Preferences to read history.")
            }
            return try await service.requestWhileConnected("thread/read", params: params)
        }
        return try await service.request("thread/read", params: params)
    }

    /// Refresh a remote reconciliation through the same bounded desktop and
    /// remote presentation callbacks. A read never creates/resumes a thread.
    public func refreshConversation(sessionID: String, authorization: (() throws -> Void)? = nil) async throws -> CodexJSONValue {
        try authorization?()
        let threadID = try mappedID(sessionID)
        let result = try await read(sessionID: sessionID)
        try Task.checkCancellation()
        try authorization?()
        guard try mappedID(sessionID) == threadID,
              let thread = result.objectValue?["thread"], thread.objectValue?["id"]?.stringValue == threadID else {
            throw CodexAppServerError.protocolViolation("Conversation identity changed during refresh")
        }
        onHydrate?(sessionID, thread)
        for observer in Array(observers.values) { observer.hydrate?(sessionID, thread) }
        return result
    }

    /// Resolve an uncertain start using an explicitly chosen stored thread.
    /// Existing mappings are immutable; this cannot replace a failed resume.
    public func recoverCreation(sessionID: String, threadID: String) async throws {
        try await admitted(sessionID) { try await recoverCreationAdmitted(sessionID: sessionID, threadID: threadID) }
    }

    private func recoverCreationAdmitted(sessionID: String, threadID: String) async throws {
        try checkEnabled()
        await ensureObservation()
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        try checkEnabled()
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

    public func startTurn(sessionID: String, input: [CodexJSONValue], authorization: (() throws -> Void)? = nil, willSubmit: (() -> Void)? = nil) async throws -> CodexJSONValue {
        try await admitted(sessionID) { try await startTurnAdmitted(sessionID: sessionID, input: input, authorization: authorization, willSubmit: willSubmit) }
    }

    private func startTurnAdmitted(sessionID: String, input: [CodexJSONValue], authorization: (() throws -> Void)?, willSubmit: (() -> Void)?) async throws -> CodexJSONValue {
        try checkEnabled()
        await ensureObservation()
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        try authorization?()
        try await attach(sessionID, authorization: authorization)
        try Task.checkCancellation()
        try checkEnabled()
        try authorization?()
        guard let state = states[sessionID], !state.needsAttention,
              state.runtime.type == "idle", state.activeTurnID == nil else {
            throw CodexAppServerError.protocolViolation("Finish the active turn or answer the pending request first")
        }
        let current = epoch
        let revision = state.revision
        update(sessionID) { $0.runtime = .init(type: "active"); $0.lastTurnStatus = nil }
        do {
            willSubmit?()
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
            // A definite RPC rejection did not launch a turn. Timeouts and
            // disconnects remain reserved until reconnect resolves uncertainty.
            if case .remote = error as? CodexAppServerError,
               states[sessionID]?.revision == revision, states[sessionID]?.activeTurnID == nil {
                update(sessionID) { $0.runtime = .init(type: "idle") }
            }
            recordFailure(error, sessionID: sessionID)
            throw error
        }
    }

    public func interrupt(sessionID: String, expectedTurnID: String? = nil,
                          authorization: (() throws -> Void)? = nil, willSubmit: (() -> Void)? = nil) async throws {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        try authorization?()
        guard let state = states[sessionID] else { return }
        let requestedTurn = expectedTurnID.flatMap { expected in
            state.pendingRequests.contains { $0.params.objectValue?["turnId"]?.stringValue == expected } ? expected : nil
        }
        guard let turnID = state.activeTurnID ?? requestedTurn else {
            if expectedTurnID != nil { throw CodexAppServerError.protocolViolation("The expected turn has completed") }
            return
        }
        guard expectedTurnID == nil || expectedTurnID == turnID else {
            throw CodexAppServerError.protocolViolation("The active turn changed; review it before interrupting")
        }
        let params: CodexJSONValue = .object([
            "threadId": .string(try mappedID(sessionID)), "turnId": .string(turnID)
        ])
        willSubmit?()
        if isEnabled { _ = try await service.request("turn/interrupt", params: params) }
        else { _ = try await service.requestWhileConnected("turn/interrupt", params: params) }
    }

    public func steer(sessionID: String, expectedTurnID: String, input: [CodexJSONValue],
                      authorization: (() throws -> Void)? = nil, willSubmit: (() -> Void)? = nil) async throws -> CodexJSONValue {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        try authorization?()
        try checkEnabled()
        guard let state = states[sessionID], state.connection == .subscribed,
              state.activeTurnID == expectedTurnID, !state.needsAttention else {
            throw CodexAppServerError.protocolViolation("The active turn changed or needs a response; review it before steering")
        }
        willSubmit?()
        return try await service.request("turn/steer", params: .object([
            "threadId": .string(try mappedID(sessionID)), "expectedTurnId": .string(expectedTurnID), "input": .array(input)
        ]))
    }

    public func requestIsAnswerable(sessionID: String, requestID: CodexJSONValue) -> Bool {
        guard let threadID = states[sessionID]?.binding.threadID else { return false }
        return replies[replyKey(threadID, requestID)] != nil
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
        update(sessionID) { _ in } // Publish consumed controls before server acknowledgment.
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

    private func attach(_ id: String, observeBusyWhileDisabled: Bool = false, authorization: (() throws -> Void)? = nil) async throws {
        let observingExisting = observeBusyWhileDisabled && states[id]?.binding.threadID != nil
            && (states[id]?.runtime.type == "active" || states[id]?.needsAttention == true)
        do {
            try authorization?()
            if !observingExisting { try checkEnabled() }
            guard !cliSessionIDs.contains(id) else {
                throw CodexAppServerError.protocolViolation("This session now uses the Codex CLI")
            }
        } catch { recordFailure(error, sessionID: id); throw error }
        guard let state = states[id] else { throw CodexAppServerError.protocolViolation("Unknown Banyan Codex session") }
        if state.isSubscribed && state.connection == .subscribed { return }
        let current = epoch
        let revision = state.revision
        do {
            try authorization?()
            // Existing-turn observation must not implicitly connect while disabled.
            if isEnabled || !observingExisting {
                try await service.connect()
                hasNativeConnection = true
            }
            try checkEpoch(current)
            if let home = await service.storageHome() {
                if let recorded = state.binding.codexHome, recorded != home {
                    throw CodexAppServerError.protocolViolation("Native Codex storage location changed. Use Codex CLI to resume this thread from its recorded storage location.")
                }
                if state.binding.codexHome == nil {
                    update(id) { $0.binding.codexHome = home }
                    await flushPersistence?()
                }
            }
        } catch { recordFailure(error, sessionID: id); throw error }
        try authorization?()
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
        var requestSent = false
        do {
            if !observingExisting { try checkEnabled() }
            let result: CodexJSONValue
            try Task.checkCancellation()
            try authorization?()
            requestSent = true
            if !isEnabled && observingExisting {
                result = try await service.requestWhileConnected(method, params: .object(params))
            } else { result = try await service.request(method, params: .object(params)) }
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
            if ["idle", "active", "notLoaded"].contains(states[id]?.runtime.type ?? "unknown") {
                unresolvedWork.remove(id)
            } else { unresolvedWork.insert(id) }
            reconcileAdmission(id)
            onHydrate?(id, thread)
            for observer in Array(observers.values) { observer.hydrate?(id, thread) }
            await flushPersistence?()
        } catch {
            // JSON-RPC method-not-found proves thread/start did not create one.
            // A timeout or malformed reply remains uncertain and must be recovered.
            if method == "thread/start" {
                var definitelyUncreated = !requestSent
                if let serverError = error as? CodexAppServerError {
                    switch serverError {
                    case .remote(code: -32601, message: _), .launch, .incompatibleVersion, .timedOut("initialize"):
                        definitelyUncreated = true
                    default: break
                    }
                }
                if definitelyUncreated { update(id) { $0.binding.creationAttempted = false } }
                else { unresolvedWork.insert(id) }
            } else if requestSent {
                // Resume may have loaded work even if its reply was lost.
                unresolvedWork.insert(id)
            }
            recordFailure(error, sessionID: id)
            throw error
        }
    }

    private func releaseIdle(_ id: String) async throws {
        guard (!isEnabled || (id != selectedSessionID && remoteObservation[id] == nil)), let state = states[id], state.canReleaseSubscription,
              let threadID = state.binding.threadID else { return }
        let current = epoch
        do {
            let params: CodexJSONValue = .object(["threadId": .string(threadID)])
            let result: CodexJSONValue
            if isEnabled { result = try await service.request("thread/unsubscribe", params: params) }
            else { result = try await service.requestWhileConnected("thread/unsubscribe", params: params) }
            try checkEpoch(current)
            guard let status = result.objectValue?["status"]?.stringValue,
                  ["unsubscribed", "notSubscribed", "notLoaded"].contains(status) else {
                throw CodexAppServerError.protocolViolation("Unknown Codex unsubscribe result")
            }
            update(id) {
                $0.isSubscribed = false
                $0.connection = .unsubscribed
                if status == "notLoaded" { $0.runtime = .init(type: "notLoaded") }
            }
            // An external turn or selection can arrive while unsubscribe awaits.
            // Reattach immediately rather than hiding its work or approvals.
            if (isEnabled && (selectedSessionID == id || remoteObservation[id] != nil)) || states[id]?.runtime.type == "active" || states[id]?.needsAttention == true {
                try await attach(id, observeBusyWhileDisabled: !isEnabled)
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
            guard let threadID = object?["threadId"]?.stringValue ?? object?["thread"]?.objectValue?["id"]?.stringValue else {
                // Global warnings/new events are inspectable, but never reduced
                // as session/turn mutations without a thread identity.
                for (id, state) in states where state.isSubscribed { publishEvent(id, method, params) }
                return
            }
            guard let id = sessionIDByThreadID[threadID] else { return }
            let completedTurnID = method == "turn/completed" ? object?["turn"]?.objectValue?["id"]?.stringValue : nil
            let endingRequests = (states[id]?.pendingRequests ?? []).filter {
                completedTurnID != nil && $0.params.objectValue?["turnId"]?.stringValue == completedTurnID
            }
            let lifecycleChanged = ["thread/status/changed", "turn/started", "turn/completed", "serverRequest/resolved", "thread/closed"].contains(method)
            if lifecycleChanged {
                if method == "thread/status/changed" {
                    let type = CodexThreadRuntime(object?["status"]).type
                    if ["idle", "active", "notLoaded"].contains(type) { unresolvedWork.remove(id) }
                    else if admission?.running.contains(id) == true { unresolvedWork.insert(id) }
                } else if ["turn/completed", "thread/closed"].contains(method) { unresolvedWork.remove(id) }
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
                        let completedID = object?["turn"]?.objectValue?["id"]?.stringValue
                        state.pendingRequests.removeAll { $0.params.objectValue?["turnId"]?.stringValue == completedID }
                        guard state.activeTurnID == nil || state.activeTurnID == completedID else { break }
                        state.lastTurnStatus = object?["turn"]?.objectValue?["status"]?.stringValue
                        state.activeTurnID = nil
                        state.runtime = .init(type: "idle")
                    case "serverRequest/resolved":
                        state.pendingRequests.removeAll { $0.id == object?["requestId"] }
                    case "thread/closed":
                        state.activeTurnID = nil
                        state.isSubscribed = false
                        state.runtime = .init(type: "notLoaded")
                        state.connection = .unsubscribed
                        state.pendingRequests = []
                    default: break
                    }
                }
            }
            if method == "turn/completed", let turnID = object?["turn"]?.objectValue?["id"]?.stringValue {
                // A delayed completion must not cancel requests from a newer turn.
                for request in endingRequests where request.params.objectValue?["turnId"]?.stringValue == turnID {
                    replies.removeValue(forKey: replyKey(threadID, request.id))?.resume(
                        returning: .error(code: -32000, message: "Codex turn ended"))
                }
            }
            if method == "serverRequest/resolved", let requestID = object?["requestId"] {
                replies.removeValue(forKey: replyKey(threadID, requestID))?.resume(
                    returning: .error(code: -32000, message: "Codex request was resolved by another client"))
            }
            if method == "thread/closed" {
                unresolvedWork.remove(id)
                reconcileAdmission(id)
                clearReplies(threadID: threadID)
            }
            publishEvent(id, method, params)
            if lifecycleChanged, (!isEnabled || id != selectedSessionID), states[id]?.canReleaseSubscription == true {
                Task { [weak self] in
                    guard let self else { return }
                    await self.acquire()
                    defer { self.release() }
                    do {
                        try await self.releaseIdle(id)
                        try await self.finishDisableIfIdle()
                    } catch { self.recordFailure(error, sessionID: id) }
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
        hasNativeConnection = false
        epoch += 1
        for id in Array(states.keys) {
            if let state = states[id], state.runtime.type == "active" || state.activeTurnID != nil || state.needsAttention {
                unresolvedWork.insert(id)
            }
            update(id) {
                $0.isSubscribed = false
                $0.connection = .failed(message)
                // Runtime is unknown, not hibernated: a turn may have been cut off.
                $0.runtime = .init()
                $0.pendingRequests = []
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
            connection = .writerConflict("Another Codex client holds this thread's writer. Exit or detach its CLI/TUI using that client's supported lifecycle, then reconnect here. For Banyan CLI terminals, use Prepare Remote Handoff, enter /quit after the turn finishes, then Check CLI Exit. Detaching only the terminal display does not release the writer. The thread and working directory are preserved. Server: \(message)")
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
        reconcileAdmission(id)
        onChange?(id, state)
        for observer in Array(observers.values) { observer.change?(id, state) }
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
