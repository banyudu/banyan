import BanyanCore
import Foundation

extension SessionStore {
    /// User-driven, exact-thread handoff for existing terminal sessions. Neither
    /// preparing nor checking types into the pane or restarts its agent.
    @discardableResult
    func codexTUIHandoff(id: String, checkOnly: Bool = false,
                         inspector: any CodexTUIProcessInspecting = CodexTUIProcessInspector()) async throws -> CodexTUIOwnership {
        guard let session = sessions.first(where: { $0.id == id }) as? TerminalSession,
              session.agentProvider == .codex, !session.isImportedHistory,
              let threadID = session.agentSessionID, !threadID.isEmpty else {
            throw ControlError.badRequest("Select an existing Codex CLI session with a known thread ID. Refresh history if its identity has not been imported yet.")
        }
        guard !session.isSuspended, !session.isFrozen else {
            throw ControlError.badRequest("Resume or unfreeze the Codex terminal before preparing Remote handoff.")
        }
        guard let backend = session.tmuxBackend as? any CodexTUIHandoffBackend else {
            throw ControlError.badRequest("This terminal backend cannot preserve a Codex handoff pane.")
        }
        guard pendingCodexTUIHandoffs.insert(id).inserted else {
            throw ControlError.badRequest("A Codex handoff check is already running for this terminal. Wait and retry.")
        }
        defer { pendingCodexTUIHandoffs.remove(id) }
        let sessionName = session.tmuxSessionName
        let cwd = session.cwd
        codexTUIOwnership[id] = nil
        let state: CodexTUIOwnership
        do {
            state = try await Task.detached(priority: .userInitiated) {
                if checkOnly {
                    return try CodexTUIHandoff.check(sessionName: sessionName, threadID: threadID,
                        backend: backend, inspector: inspector)
                }
                _ = try CodexTUIHandoff.prepare(threadID: threadID, cwd: cwd,
                    sessionName: sessionName, backend: backend, inspector: inspector)
                return CodexTUIOwnership.awaitingCLIExit
            }.value
        } catch CodexTUIHandoffError.busy(let message) {
            codexTUIOwnership[id] = .init(threadID: threadID, state: .turnPending)
            throw CodexTUIHandoffError.busy(message)
        }
        guard sessions.contains(where: { $0 === session }), session.agentSessionID == threadID,
              session.cwd == cwd, session.tmuxSessionName == sessionName else {
            throw ControlError.badRequest("The session changed during handoff. Select its current thread and retry.")
        }
        codexTUIOwnership[id] = .init(threadID: threadID, state: state)
        return state
    }
}
