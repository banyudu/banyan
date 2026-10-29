import Foundation

/// Shared rules for deciding whether and how a coding-agent session can be
/// resumed from its imported history.
public enum SessionRecoveryPolicy {
    /// Whether a missing tmux backend can be recreated automatically with the
    /// conversation's exact provider identity.
    ///
    /// Launch recovery must never fall back to the original command: an active
    /// agent's command contains its initial prompt, so replaying it can start a
    /// second, unrelated conversation. Terminal rows and rows without a saved
    /// provider ID therefore stay in the explicit recovery flow.
    public static func allowsAutomaticBackendRecovery(
        status: SessionStatus,
        provider: CodingAgentProvider?,
        agentSessionID: String?
    ) -> Bool {
        guard ![.closed, .completed, .failed].contains(status),
              let provider,
              [.codex, .claude].contains(provider) || provider.isOpencodeBacked,
              let agentSessionID,
              !agentSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return false
        }
        return true
    }

    public static func requiresDeepHistoryRecovery(
        status: SessionStatus,
        provider: CodingAgentProvider?,
        agentSessionID: String?
    ) -> Bool {
        guard status == .closed,
              let provider,
              ( [.codex, .claude].contains(provider) || provider.isOpencodeBacked ),
              (agentSessionID?.isEmpty != false)
        else {
            return false
        }
        return true
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
        guard let provider,
              ( [.codex, .claude].contains(provider) || provider.isOpencodeBacked ),
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
