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

    /// Builds a recovery plan through the caller's history backend. This keeps
    /// recovery behavior injectable for frontends and test doubles while the
    /// eligibility rules remain shared here.
    public static func resumePlan(
        status: SessionStatus,
        provider: CodingAgentProvider?,
        agentSessionID: String?,
        cwd: String,
        history: any SessionHistoryBackend
    ) -> SessionResumePolicy.Plan? {
        guard status == .closed,
              let provider,
              [.codex, .claude].contains(provider),
              let agentSessionID,
              !agentSessionID.isEmpty else {
            return nil
        }
        return SessionResumePolicy.plan(
            provider: provider,
            sourceID: agentSessionID,
            cwd: cwd,
            prompt: nil,
            transcriptURL: nil,
            trimmed: false,
            history: history
        )
    }

    public static func missingResumeMessage(provider: CodingAgentProvider?) -> String {
        let providerName = provider?.displayName ?? "coding-agent"
        return "No resumable \(providerName) session was found for this working directory. The original command was not restarted."
    }
}
