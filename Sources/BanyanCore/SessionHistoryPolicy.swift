import Foundation

/// Shared classification rules for sessions shown in local history.
public enum SessionHistoryPolicy {
    /// `hasIssueLink` is an autoclosure because the guards above it reject most
    /// sessions, but a plain `Bool` argument is evaluated eagerly at the call site —
    /// so the sidebar was resolving an issue link for every session it was about to
    /// discard. Callers pass the same expression as before.
    public static func isLocalHistorySession(
        status: SessionStatus,
        isImportedHistory: Bool,
        provider: CodingAgentProvider?,
        hasIssueLink: @autoclosure () -> Bool
    ) -> Bool {
        guard status == .closed, !isImportedHistory else { return false }
        guard let provider, [.codex, .claude].contains(provider) else { return false }
        return hasIssueLink()
    }
}
