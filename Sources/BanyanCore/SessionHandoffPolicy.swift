import Foundation

/// Determines whether a session is eligible for the optional worktree handoff
/// action. The dispatch mechanism remains frontend-specific.
public enum SessionHandoffPolicy {
    public static let commandEnvironmentKey = "BANYAN_HANDOFF_COMMAND"

    /// Resolves the executable that implements the handoff workflow, or nil
    /// when none is installed. Handoff is an optional integration: every
    /// frontend affordance should stay hidden while this returns nil.
    public static func commandPath(
        environment: [String: String],
        homeDirectory: String,
        isExecutableFile: (String) -> Bool
    ) -> String? {
        let candidate: String
        if let override = environment[commandEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !override.isEmpty {
            if override == "~" || override.hasPrefix("~/") {
                candidate = homeDirectory + String(override.dropFirst(1))
            } else {
                candidate = override
            }
        } else {
            candidate = homeDirectory + "/bin/handoff"
        }
        return isExecutableFile(candidate) ? candidate : nil
    }

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
