import Foundation
import Testing
@testable import BanyanCore

@Test func sessionResumeUsesProviderAndShortSourceIDPrefix() {
    #expect(
        SessionResumePolicy.sessionIDPrefix(
            provider: .codex,
            sourceID: "019efe8d-0514-72a2-ad62-daea0b976dcf"
        ) == "codex-019efe8d"
    )
    #expect(
        SessionResumePolicy.sessionIDPrefix(provider: .claude, sourceID: "short") == "claude-short"
    )
}

@Test func sessionResumePlanUsesPreparedSourceAndCommand() {
    let plan = SessionResumePolicy.plan(
        provider: .codex,
        sourceID: "original",
        cwd: "/tmp/project",
        prompt: "continue",
        transcriptURL: URL(fileURLWithPath: "/tmp/original.jsonl"),
        trimmed: true,
        history: ResumePolicyTestHistory()
    )

    #expect(plan == SessionResumePolicy.Plan(
        sourceID: "trimmed",
        command: "agent --resume trimmed --prompt continue",
        usedTrimmedTranscript: true
    ))
}

private struct ResumePolicyTestHistory: SessionHistoryBackend {
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
        "agent --resume \(sourceID) --prompt \(prompt ?? "")"
    }

    func prepareTrimmedTranscript(
        provider: CodingAgentProvider,
        sourceID: String,
        cwd: String,
        transcriptURL: URL?
    ) -> String? {
        "trimmed"
    }
}
