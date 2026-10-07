import BanyanCore
import Foundation
import SwiftUI

/// Native thread identity and lifecycle. Transcript rendering and approval
/// controls can consume state/pendingRequests plus coordinator.read/onEvent.
@MainActor
final class CodexSession: BanyanSession {
    @Published private(set) var state: CodexThreadState
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

/// Lifecycle surface until the conversation view is integrated.
struct CodexSessionDetail: View {
    @ObservedObject var session: CodexSession

    var body: some View {
        ContentUnavailableView {
            Label("Codex Thread", systemImage: "bubble.left.and.bubble.right")
        } description: {
            Text(session.state.connection.message ?? statusDescription)
            if let threadID = session.state.binding.threadID { Text(threadID).font(.caption).textSelection(.enabled) }
        } actions: {
            Button("Reconnect") { session.reconnect() }
        }
    }

    private var statusDescription: String {
        if session.state.needsAttention { return "Codex is waiting for a response. The subscription remains active." }
        if session.state.runtime.type == "active" { return "A Codex turn is running." }
        if session.state.connection == .connecting { return "Connecting to Codex…" }
        return "Thread connected. Conversation controls will be available in the native conversation view."
    }
}
