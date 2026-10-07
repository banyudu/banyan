import BanyanCore
import Foundation
import SwiftUI

/// Native thread identity, conversation, and actions survive view selection.
@MainActor
final class CodexSession: BanyanSession {
    @Published private(set) var state: CodexThreadState
    @Published private(set) var conversation = CodexConversation()
    @Published private(set) var actionError: String?
    @Published private(set) var isSending = false
    @Published private(set) var submittedRequestIDs: Set<String> = []
    @Published var draft = ""
    @Published var remoteStatus: String?
    let coordinator: CodexThreadCoordinator

    init(snapshot: SessionSnapshot, coordinator: CodexThreadCoordinator,
         displayContext: SessionProjectContext? = nil, telemetry: PerformanceTelemetry,
         host: HostRuntimeContext, githubReferenceCache: GitHubReferenceCache? = nil) throws {
        guard let binding = snapshot.codex else {
            throw CodexAppServerError.protocolViolation("Native Codex session is missing its thread binding")
        }
        try coordinator.register(sessionID: snapshot.id, binding: binding)
        self.state = coordinator.states[snapshot.id]!
        self.coordinator = coordinator
        super.init(
            id: snapshot.id, title: snapshot.title, titleURL: snapshot.titleURL,
            titleURLWasAutoDetected: snapshot.titleURLWasAutoDetected,
            generatedTitle: snapshot.generatedTitle, isTitlePinned: snapshot.isTitlePinned,
            cwd: binding.cwd, command: "", status: snapshot.status, tone: snapshot.tone,
            parentSessionID: snapshot.parentSessionID, agentSessionID: binding.threadID,
            createdAt: snapshot.createdAt, updatedAt: snapshot.updatedAt,
            isRestored: true, isSuspended: snapshot.isSuspended, displayContext: displayContext,
            agentProvider: .codex, agentModelID: binding.settings.model,
            telemetry: telemetry, host: host, githubReferenceCache: githubReferenceCache
        )
        reportedTitle = snapshot.reportedTitle
    }

    override var backendKind: SessionBackendKind { .codex }
    override var codexBinding: CodexThreadBinding? { state.binding }
    override var titleSeed: String { "Codex" }
    override var closeEndsAgentWork: Bool { false }
    override var backingSessionName: String { "Codex thread" }
    override var closeConsequence: String {
        "Closing \(displayTitle) hides its row. Active turns and pending requests remain observed until safe to detach. Its thread and working directory are preserved."
    }
    override func siblingLaunch(profiles: [NewSessionLaunch], codexLaunchMode: CodexLaunchMode) -> SessionLaunchSpec {
        .codex(state.binding.settings)
    }

    func apply(_ next: CodexThreadState) {
        if next.connection == .connecting, state.connection != .connecting { conversation.beginHydration() }
        if next.connection == .unsubscribed, state.connection != .unsubscribed { conversation.releaseHistory() }
        submittedRequestIDs.formIntersection(next.pendingRequests.map { $0.id.inspectableText })
        state = next
        agentSessionID = next.binding.threadID
        markDetectedAgentModel(next.binding.settings.model, isExact: true)
        // A hidden/parked row must still hold busy work; never call it hibernated.
        guard status != .closed else { touch(); return }
        let nextStatus: SessionStatus
        switch next.connection {
        case .writerConflict, .unavailable, .failed: nextStatus = .failed
        default:
            if next.needsAttention { nextStatus = .asking }
            else if next.runtime.type == "active" || next.activeTurnID != nil { nextStatus = .executing }
            else if next.runtime.type == "systemError" || ["failed", "interrupted"].contains(next.lastTurnStatus ?? "") { nextStatus = .failed }
            else if next.lastTurnStatus == "completed" { nextStatus = .needInput }
            else { nextStatus = .idle }
        }
        mark(status: nextStatus, tone: PuckSessionStatusPolicy.tone(for: nextStatus))
        touch()
    }

    func receive(method: String, params: CodexJSONValue) {
        // Queued item deltas after a safe unsubscribe must not recreate an
        // idle background cache. Active work/requests still own observation.
        if state.connection == .unsubscribed, state.activeTurnID == nil, !state.needsAttention { return }
        guard let threadID = state.binding.threadID else { return }
        conversation.receive(method: method, params: params, threadID: threadID)
    }

    func hydrate(thread: CodexJSONValue) {
        guard let threadID = state.binding.threadID else { return }
        conversation.hydrate(thread: thread, threadID: threadID)
    }

    var canSend: Bool {
        !isSending && state.connection == .subscribed && !state.needsAttention
            && (state.activeTurnID != nil || state.runtime.type == "idle")
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func sendDraft() async {
        guard canSend else { return }
        let text = draft
        let turnID = state.activeTurnID
        isSending = true
        actionError = nil
        defer { isSending = false }
        do {
            let input: [CodexJSONValue] = [.object(["type": .string("text"), "text": .string(text)])]
            if let turnID {
                _ = try await coordinator.steer(sessionID: id, expectedTurnID: turnID, input: input)
            } else {
                _ = try await coordinator.startTurn(sessionID: id, input: input)
            }
            if draft == text { draft = "" }
        } catch is CancellationError { actionError = "Queued turn cancelled. Your draft is preserved." }
        catch { actionError = error.localizedDescription }
    }

    func interrupt() async {
        actionError = nil
        do { try await coordinator.interrupt(sessionID: id) }
        catch { actionError = error.localizedDescription }
    }

    func respond(_ request: CodexServerRequest, decision: CodexApprovalDecision) {
        do { try submit(request, reply: CodexConversationRequest(request).approvalReply(decision)) }
        catch { actionError = error.localizedDescription }
    }

    func answer(_ request: CodexServerRequest, answers: [String: String]) {
        do { try submit(request, reply: CodexConversationRequest(request).inputReply(answers)) }
        catch { actionError = error.localizedDescription }
    }

    func skipInput(_ request: CodexServerRequest) {
        do { try submit(request, reply: CodexConversationRequest(request).skippedInputReply) }
        catch { actionError = error.localizedDescription }
    }

    func cancelInput(_ request: CodexServerRequest) async {
        actionError = nil
        do {
            // Interrupt the requested turn before unblocking its tool. Never
            // send a made-up option or interrupt a successor turn.
            if let turnID = request.params.objectValue?["turnId"]?.stringValue {
                try await coordinator.interrupt(sessionID: id, expectedTurnID: turnID)
            }
            if state.pendingRequests.contains(where: { $0.id == request.id }), !submittedRequestIDs.contains(request.id.inspectableText) {
                try submit(request, reply: CodexConversationRequest(request).skippedInputReply)
            }
        } catch { actionError = error.localizedDescription }
    }

    func rejectUnsupported(_ request: CodexServerRequest) {
        do { try submit(request, reply: .error(code: -32601, message: "Banyan does not support this request: \(request.method)")) }
        catch { actionError = error.localizedDescription }
    }

    private func submit(_ request: CodexServerRequest, reply: CodexServerReply) throws {
        try coordinator.respond(sessionID: id, requestID: request.id, reply: reply)
        submittedRequestIDs.insert(request.id.inspectableText)
        actionError = nil
    }

    func reconnect() {
        Task { [weak self] in
            guard let self else { return }
            try? await coordinator.connect(sessionID: id) // Coordinator publishes failures.
        }
    }

    func reopen() {
        isSuspended = false
        status = .idle
        apply(state)
        reconnect()
    }

    override func suspend() {
        guard state.runtime.type != "active", state.activeTurnID == nil, !state.needsAttention else { return }
        super.suspend()
        detachIfIdle()
    }

    override func closeBackingSession() {
        super.closeBackingSession()
        detachIfIdle()
    }

    private func detachIfIdle() {
        Task { [weak self] in
            guard let self else { return }
            try? await coordinator.detach(sessionID: id)
        }
    }
}
