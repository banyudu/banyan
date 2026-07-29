import Foundation

/// Determines whether a session is eligible for the optional worktree handoff
/// action. The dispatch mechanism remains frontend-specific.
public enum SessionHandoffPolicy {
    public static func canDispatch(
        isImportedHistory: Bool,
        provider: CodingAgentProvider?,
        status: SessionStatus,
        isGitWorktree: Bool,
        branch: String?,
        isDefaultBranch: Bool
    ) -> Bool {
        guard !isImportedHistory,
              provider != nil,
              status.isCodingAgentIdle,
              isGitWorktree,
              let branch,
              !isDefaultBranch else {
            return false
        }
        return branch != "main" && branch != "master"
    }
}
