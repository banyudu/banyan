import Foundation

/// Shared classification rules for sessions shown in local history.
public enum SessionHistoryPolicy {
    public static func isLocalHistorySession(
        status: SessionStatus,
        isImportedHistory: Bool,
        provider: CodingAgentProvider?,
        hasIssueLink: Bool
    ) -> Bool {
        guard status == .closed, !isImportedHistory else { return false }
        guard let provider, [.codex, .claude].contains(provider) else { return false }
        return hasIssueLink
    }
}
