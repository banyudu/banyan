import Foundation

/// Frontend-independent decisions used while restoring and supervising sessions.
public enum SessionLifecyclePolicy {
    public static func statusAfterTerminalExit(
        currentStatus: SessionStatus,
        hasBackingSession: Bool,
        exitCode: Int32?
    ) -> SessionStatus? {
        guard currentStatus != .closed else { return nil }
        if hasBackingSession {
            return .running
        }
        return exitCode == 0 ? .completed : .failed
    }

    public static func isWorkable(
        status: SessionStatus,
        isImportedHistory: Bool
    ) -> Bool {
        !isImportedHistory
            && status != .closed
            && [.asking, .needInput, .idle].contains(status)
    }

    public static func participatesInSupervisorTick(
        isProcessStarted: Bool,
        isRestored: Bool
    ) -> Bool {
        isProcessStarted || isRestored
    }

    public static func restoredStatus(snapshotStatus: SessionStatus) -> SessionStatus {
        snapshotStatus
    }

    public static func shouldMarkForRecovery(
        status: SessionStatus,
        tmuxSessionName: String,
        liveTmuxSessionNames: Set<String>
    ) -> Bool {
        ![.closed, .completed, .failed].contains(status)
            && !liveTmuxSessionNames.contains(tmuxSessionName)
    }

    public static func isOngoingCodingAgentSession(
        status: SessionStatus,
        provider: CodingAgentProvider?
    ) -> Bool {
        guard [.codex, .claude, .deepseek, .opencode].contains(provider) else { return false }
        return ![.completed, .failed, .closed].contains(status)
    }
}
