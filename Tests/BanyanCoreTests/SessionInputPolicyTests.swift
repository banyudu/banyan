import Foundation
import Testing
@testable import BanyanCore

@Test func inputPolicyRecognizesConversationResets() {
    #expect(SessionInputPolicy.isConversationResetCommand("  /CLEAR "))
    #expect(SessionInputPolicy.isConversationResetCommand("/new"))
    #expect(!SessionInputPolicy.isConversationResetCommand("continue"))
}

@Test func inputPolicyMarksStartedAgentSessionsAsExecuting() {
    #expect(SessionInputPolicy.statusAfterSubmittedInput(
        isImportedHistory: false,
        isProcessStarted: true,
        status: .needInput,
        provider: .codex
    ) == .executing)
    #expect(SessionInputPolicy.statusAfterSubmittedInput(
        isImportedHistory: false,
        isProcessStarted: true,
        status: .completed,
        provider: .codex
    ) == nil)
    #expect(SessionInputPolicy.statusAfterSubmittedInput(
        isImportedHistory: true,
        isProcessStarted: true,
        status: .asking,
        provider: .claude
    ) == nil)
}

@Test func inputPolicyFiltersTrivialSubmittedTitles() {
    #expect(SessionInputPolicy.submittedPromptTitle(from: "Fix the provider icon") == "Fix the provider icon")
    #expect(SessionInputPolicy.submittedPromptTitle(from: "yes") == nil)
    #expect(SessionInputPolicy.submittedPromptTitle(from: "/clear") == nil)
}

@Test func inputPolicyNormalizesDirectoriesAndTitleURLs() {
    #expect(SessionInputPolicy.normalizedTitleURL("  https://example.com/issue  ") == "https://example.com/issue")
    #expect(SessionInputPolicy.normalizedTitleURL("   ") == nil)
    #expect(SessionInputPolicy.normalizedDirectory(" /tmp/project/.. ") == "/tmp")
}

@Test func inputPolicyUsesExplicitHomeDirectoryForCurrentDirectoryTitles() {
    #expect(SessionInputPolicy.titleTracksCurrentDirectory(
        "~/project",
        isTitlePinned: false,
        cwd: "/home/test/project",
        homeDirectory: "/home/test"
    ))
    #expect(!SessionInputPolicy.titleTracksCurrentDirectory(
        "custom title",
        isTitlePinned: false,
        cwd: "/home/test/project",
        homeDirectory: "/home/test"
    ))
}
