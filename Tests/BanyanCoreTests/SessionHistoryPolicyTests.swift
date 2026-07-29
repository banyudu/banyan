import Testing
@testable import BanyanCore

@Test func localHistoryPolicyRequiresClosedLocalAgentWithIssueLink() {
    #expect(SessionHistoryPolicy.isLocalHistorySession(
        status: .closed,
        isImportedHistory: false,
        provider: .codex,
        hasIssueLink: true
    ))
    #expect(!SessionHistoryPolicy.isLocalHistorySession(
        status: .running,
        isImportedHistory: false,
        provider: .codex,
        hasIssueLink: true
    ))
    #expect(!SessionHistoryPolicy.isLocalHistorySession(
        status: .closed,
        isImportedHistory: true,
        provider: .claude,
        hasIssueLink: true
    ))
    #expect(!SessionHistoryPolicy.isLocalHistorySession(
        status: .closed,
        isImportedHistory: false,
        provider: .gemini,
        hasIssueLink: true
    ))
    #expect(!SessionHistoryPolicy.isLocalHistorySession(
        status: .closed,
        isImportedHistory: false,
        provider: .claude,
        hasIssueLink: false
    ))
}
