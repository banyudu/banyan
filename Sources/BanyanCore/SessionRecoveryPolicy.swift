import Foundation

/// Shared rules for deciding whether and how a closed coding-agent session can
/// be resumed from its imported history.
public enum SessionRecoveryPolicy {
    public static func requiresDeepHistoryRecovery(
        status: SessionStatus,
        provider: CodingAgentProvider?,
        agentSessionID: String?
    ) -> Bool {
        status == .closed
            && provider.map { [.codex, .claude].contains($0) } == true
            && (agentSessionID?.isEmpty != false)
    }

    public static func resumeCommand(
        status: SessionStatus,
        provider: CodingAgentProvider?,
        agentSessionID: String?,
        cwd: String
    ) -> String? {
        guard status == .closed,
              let provider,
              [.codex, .claude].contains(provider),
              let agentSessionID,
              !agentSessionID.isEmpty else {
            return nil
        }
        return AgentSessionHistory.resumeCommand(
            provider: provider,
            sourceID: agentSessionID,
            cwd: cwd
        )
    }

    public static func missingResumeMessage(provider: CodingAgentProvider?) -> String {
        let providerName = provider?.displayName ?? "coding-agent"
        return "No resumable \(providerName) session was found for this working directory. The original command was not restarted."
    }
}
