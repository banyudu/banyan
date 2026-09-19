import Foundation

/// Decides which stranded sessions Banyan may put back to work on its own at
/// launch, and how fast.
///
/// A machine restart stops the tmux server, so every active session comes back
/// needing recovery. Recovering one is otherwise identical to pressing
/// **Recover All**; the difference is that nothing here may block on the user,
/// because it runs while the main window is still being restored.
public enum SessionAutoRecoveryPolicy {
    /// Sessions started before pausing for `batchInterval`. Each recovery forks a
    /// tmux session and an agent process, and a reboot routinely strands dozens,
    /// so starting them all in one runloop turn would make the first minute
    /// after login unusable.
    public static let batchSize = 4

    /// Seconds between batches.
    public static let batchInterval: TimeInterval = 0.75

    /// `hasProjectFolderAccess` is resolved by the frontend against whatever
    /// permission model it has. Auto-recovery must never be what raises a folder
    /// permission prompt: a session whose working directory is not already
    /// readable stays behind for the manual recovery banner, which runs after the
    /// window is up and can safely present one. The same gate keeps a deleted
    /// worktree out — recreating it is a git write, not something to do unwatched
    /// at login.
    ///
    /// Parked sessions are excluded for the reason `recover` unparks explicitly:
    /// parking is a deliberate "stop spending anything on this", and a reboot is
    /// not the user revoking it.
    public static func canAutoRecover(
        needsRecovery: Bool,
        isImportedHistory: Bool,
        isSuspended: Bool,
        hasProjectFolderAccess: Bool
    ) -> Bool {
        needsRecovery
            && !isImportedHistory
            && !isSuspended
            && hasProjectFolderAccess
    }

    /// Splits the eligible sessions into the batches the launch pass starts.
    public static func batches<T>(_ sessions: [T], size: Int = batchSize) -> [[T]] {
        guard size > 0 else {
            return sessions.isEmpty ? [] : [sessions]
        }
        return stride(from: 0, to: sessions.count, by: size).map { start in
            Array(sessions[start..<min(start + size, sessions.count)])
        }
    }
}
