import Foundation
import Testing
@testable import BanyanCore

@Test func inputPolicyRecognizesConversationResets() {
    #expect(SessionInputPolicy.isConversationResetCommand("  /CLEAR "))
    #expect(SessionInputPolicy.isConversationResetCommand("/new"))
    #expect(!SessionInputPolicy.isConversationResetCommand("continue"))
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
