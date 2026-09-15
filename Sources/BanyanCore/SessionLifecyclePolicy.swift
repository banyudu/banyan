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

    /// Sessions that are blocked on a human decision or input.
    /// Deliberately narrower than `isWorkable`: an `idle` shell is quiet, not
    /// blocked, while a `failed` one does need a call. The set is the top of
    /// `SessionStatus.priority` — asking, need-input, failed — so attention
    /// navigation visits sessions in the same order the sidebar already sorts
    /// them.
    /// Parked sessions are excluded whatever their status: nothing observes one,
    /// so the status it was parked at is frozen and would keep answering this
    /// question forever, which is the competition for attention parking exists
    /// to end.
    public static func needsAttention(
        status: SessionStatus,
        isImportedHistory: Bool,
        isSuspended: Bool
    ) -> Bool {
        !isImportedHistory
            && !isSuspended
            && [.asking, .needInput, .failed].contains(status)
    }

    /// A suspended session is an explicit gate rather than something inferred
    /// from status: parking leaves the tmux session and its agent running, so a
    /// parked row still looks started/restored and would otherwise keep paying
    /// the full per-tick inspection cost.
    public static func participatesInSupervisorTick(
        isProcessStarted: Bool,
        isRestored: Bool,
        isSuspended: Bool
    ) -> Bool {
        guard !isSuspended else { return false }
        return isProcessStarted || isRestored
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
        guard [.codex, .claude, .deepseek, .opencode, .hunyuan, .muse, .xiaomiMiMo, .minimax, .zai].contains(provider) else { return false }
        return ![.completed, .failed, .closed].contains(status)
    }
}
