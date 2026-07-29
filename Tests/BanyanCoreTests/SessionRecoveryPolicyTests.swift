import Foundation
import Testing
@testable import BanyanCore

@Test func recoveryPolicyRequiresHistoryOnlyForClosedSupportedAgentsWithoutIDs() {
    #expect(SessionRecoveryPolicy.requiresDeepHistoryRecovery(
        status: .closed,
        provider: .codex,
        agentSessionID: nil
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

@Test func recoveryPolicyBuildsProviderSpecificResumeCommands() {
    #expect(SessionRecoveryPolicy.resumeCommand(
        status: .closed,
        provider: .codex,
        agentSessionID: "abc",
        cwd: "/tmp/project"
    ) == "'codex' 'resume' '-C' '/tmp/project' 'abc'")
    #expect(SessionRecoveryPolicy.resumeCommand(
        status: .closed,
        provider: .claude,
        agentSessionID: "abc",
        cwd: "/tmp/project"
    ) == "'claude' '--resume' 'abc'")
    #expect(SessionRecoveryPolicy.resumeCommand(
        status: .running,
        provider: .codex,
        agentSessionID: "abc",
        cwd: "/tmp/project"
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
