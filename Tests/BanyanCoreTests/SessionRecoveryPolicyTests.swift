import Foundation
import Testing
@testable import BanyanCore

@Test func recoveryPolicyRequiresHistoryOnlyForClosedSupportedAgentsWithoutIDs() {
    #expect(SessionRecoveryPolicy.requiresDeepHistoryRecovery(
        status: .closed,
        provider: .codex,
        agentSessionID: nil
    ))
    #expect(SessionRecoveryPolicy.requiresDeepHistoryRecovery(
        status: .closed,
        provider: .opencode,
        agentSessionID: nil
    ))
    #expect(SessionRecoveryPolicy.requiresDeepHistoryRecovery(
        status: .closed,
        provider: .muse,
        agentSessionID: ""
    ))
    #expect(!SessionRecoveryPolicy.requiresDeepHistoryRecovery(
        status: .running,
        provider: .codex,
        agentSessionID: nil
    ))
    #expect(!SessionRecoveryPolicy.requiresDeepHistoryRecovery(
        status: .closed,
        provider: .gemini,
        agentSessionID: nil
    ))
}

@Test func startupRecoveryRequiresAnActiveSupportedAgentWithAnExactID() {
    #expect(SessionRecoveryPolicy.allowsAutomaticBackendRecovery(
        status: .needInput,
        provider: .codex,
        agentSessionID: "thread-saved"
    ))
    #expect(SessionRecoveryPolicy.allowsAutomaticBackendRecovery(
        status: .executing,
        provider: .claude,
        agentSessionID: "session-saved"
    ))
    #expect(SessionRecoveryPolicy.allowsAutomaticBackendRecovery(
        status: .running,
        provider: .opencode,
        agentSessionID: "ses_saved"
    ))
    #expect(!SessionRecoveryPolicy.allowsAutomaticBackendRecovery(
        status: .running,
        provider: .codex,
        agentSessionID: nil
    ))
    #expect(!SessionRecoveryPolicy.allowsAutomaticBackendRecovery(
        status: .running,
        provider: .claude,
        agentSessionID: "  "
    ))
    for status in [SessionStatus.closed, .completed, .failed] {
        #expect(!SessionRecoveryPolicy.allowsAutomaticBackendRecovery(
            status: status,
            provider: .codex,
            agentSessionID: "thread-saved"
        ))
    }
    #expect(!SessionRecoveryPolicy.allowsAutomaticBackendRecovery(
        status: .running,
        provider: .gemini,
        agentSessionID: "session-saved"
    ))
}

@Test func recoveryPolicyBuildsProviderSpecificResumeCommands() {
    let history = DefaultSessionHistoryBackend(
        homeDirectory: URL(fileURLWithPath: NSHomeDirectory())
    )
    #expect(SessionRecoveryPolicy.resumePlan(
        status: .closed,
        provider: .codex,
        agentSessionID: "abc",
        cwd: "/tmp/project",
        history: history
    )?.command == "'codex' 'resume' '-C' '/tmp/project' 'abc'")
    #expect(SessionRecoveryPolicy.resumePlan(
        status: .closed,
        provider: .claude,
        agentSessionID: "abc",
        cwd: "/tmp/project",
        history: history
    )?.command == "'claude' '--resume' 'abc'")
    #expect(SessionRecoveryPolicy.resumePlan(
        status: .closed,
        provider: .opencode,
        agentSessionID: "ses_abc123",
        cwd: "/tmp/project",
        history: history
    )?.command == "'opencode' '--session' 'ses_abc123'")
    #expect(SessionRecoveryPolicy.resumePlan(
        status: .running,
        provider: .codex,
        agentSessionID: "abc",
        cwd: "/tmp/project",
        history: history
    ) == nil)
}

@Test func recoveryPolicyUsesInjectedHistoryBackendForResumePlans() {
    let plan = SessionRecoveryPolicy.resumePlan(
        status: .closed,
        provider: .claude,
        agentSessionID: "session-123",
        cwd: "/tmp/project",
        history: RecoveryPolicyTestHistory()
    )

    #expect(plan?.sourceID == "session-123")
    #expect(plan?.command == "injected-resume session-123")
}

private struct RecoveryPolicyTestHistory: SessionHistoryBackend {
    func load(maxPerProvider limit: Int) -> [ImportedAgentSession] { [] }

    func sourceID(fromImportedSessionID id: String, provider: CodingAgentProvider) -> String? {
        nil
    }

    func resumeCommand(
        provider: CodingAgentProvider,
        sourceID: String,
        cwd: String,
        prompt: String?
    ) -> String? {
        "injected-resume \(sourceID)"
    }

    func prepareTrimmedTranscript(
        provider: CodingAgentProvider,
        sourceID: String,
        cwd: String,
        transcriptURL: URL?
    ) -> String? {
        nil
    }
}

@Test func recoveryPolicyExplainsMissingHistory() {
    #expect(SessionRecoveryPolicy.missingResumeMessage(provider: .claude).contains("No resumable Claude session"))
    #expect(SessionRecoveryPolicy.missingResumeMessage(provider: nil).contains("coding-agent"))
}
