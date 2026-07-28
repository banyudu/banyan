import Foundation

/// Frontend-independent decisions used while restoring and supervising sessions.
public enum SessionLifecyclePolicy {
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
        guard provider == .codex || provider == .claude else { return false }
        return ![.completed, .failed, .closed].contains(status)
    }
}
