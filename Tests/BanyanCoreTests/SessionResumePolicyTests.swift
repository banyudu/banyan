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
