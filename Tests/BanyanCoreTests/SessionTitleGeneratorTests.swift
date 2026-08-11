import Testing
@testable import BanyanCore

@Test func titleFromPromptPreservesFullURL() {
    let title = SessionTitleGenerator.titleFromPrompt("https://github.com/2enai/themis/pull/70")
    #expect(title != nil)
    #expect(title!.contains("github.com"))
    #expect(title!.contains("pull/70"))
}

@Test func titleFromPromptPreservesFilenameInSentence() {
    let title = SessionTitleGenerator.titleFromPrompt("Fix the bug in SessionTitleGenerator.swift now")
    #expect(title != nil)
    #expect(title!.contains("SessionTitleGenerator.swift"))
}

@Test func titleFromPromptPreservesVersionNumber() {
    let title = SessionTitleGenerator.titleFromPrompt("Upgrade to version 1.2.3 please")
    #expect(title != nil)
    #expect(title!.contains("1.2.3"))
}

@Test func titleFromPromptTruncatesAtRealSentenceBoundary() {
    let title = SessionTitleGenerator.titleFromPrompt("Do this. Then that.")
    #expect(title == "Do this.")
}

@Test func titleFromPromptTruncatesAtExclamationMark() {
    let title = SessionTitleGenerator.titleFromPrompt("Fix this now! And that too")
    #expect(title == "Fix this now!")
}

@Test func titleFromPromptTruncatesAtQuestionMark() {
    let title = SessionTitleGenerator.titleFromPrompt("What is this? Let me check")
    #expect(title == "What is this?")
}

@Test func titleFromPromptPreservesHostname() {
    let title = SessionTitleGenerator.titleFromPrompt("Check api.example.com for errors")
    #expect(title != nil)
    #expect(title!.contains("api.example.com"))
}

@Test func titleFromPromptHandlsDotAtEndOfLine() {
    let title = SessionTitleGenerator.titleFromPrompt("Fix the bug.")
    #expect(title == "Fix the bug.")
}

@Test func titleFromPromptPreservesIPAddress() {
    let title = SessionTitleGenerator.titleFromPrompt("Connect to 192.168.1.1 and check status")
    #expect(title != nil)
    #expect(title!.contains("192.168.1.1"))
}
