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

    /// Longest failure detail we paste into the alert. Past this the dialog
    /// stops being readable and starts being a log viewer.
    private static let maxDetailLines = 6
    private static let maxDetailCharacters = 600

    /// Builds the alert text for a dispatch that failed after the session was
    /// already closed.
    ///
    /// The reason always lives in the command's own output, which used to be
    /// routed to `/dev/null`: a `~/bin/handoff` shim pointing at a renamed
    /// binary and a genuine dispatch failure produced the same three-word
    /// dialog, and neither said which had happened.
    ///
    /// Pass `exitStatus: nil` when the command could not be launched at all;
    /// `output` then carries the launch error instead of process output.
    public static func dispatchFailureNotice(exitStatus: Int32?, output: String) -> String {
        var notice = "Handoff could not be started"
        if let exitStatus {
            notice += " (exit \(exitStatus))"
        }
        notice += ". The session was restored."
        let detail = dispatchFailureDetail(output)
        guard !detail.isEmpty else { return notice }
        return notice + "\n\n" + detail
    }

    private static func dispatchFailureDetail(_ output: String) -> String {
        let lines = CommandOutputText.strippingANSIEscapes(output)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return "" }
        // A CLI explains itself on the way out, so keep the tail, not the head.
        let detail = lines.suffix(maxDetailLines).joined(separator: "\n")
        guard detail.count > maxDetailCharacters else { return detail }
        return "…" + String(detail.suffix(maxDetailCharacters))
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
