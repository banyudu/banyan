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

@Test func titleFromPromptPreservesMixedLanguageText() {
    let title = SessionTitleGenerator.titleFromPrompt("检查 web-search provider 的路由")
    #expect(title == "检查 web-search provider 的路由")
}

@Test func titleFromPromptPreservesIssueReferenceInPrompt() {
    let title = SessionTitleGenerator.titleFromPrompt("work on TASK-123")
    #expect(title == "work on TASK-123")
}

@Test func titleFromPromptStripsLeadingMarkerBeforePolitePrefix() {
    let title = SessionTitleGenerator.titleFromPrompt("› I want to limit our dev/lab environment to be only accessible")
    #expect(title != nil)
    #expect(!title!.lowercased().hasPrefix("i want to"))
    #expect(title!.lowercased().hasPrefix("limit our dev/lab"))
    #expect(!title!.contains("›"))
}

@Test func titleFromPromptStripsPolitePrefix() {
    let title = SessionTitleGenerator.titleFromPrompt("I want to limit our dev/lab environment to be only accessible")
    #expect(title == "limit our dev/lab environment to be only accessible")
}

@Test func titleFromPromptReplacesURLWithPlaceholder() {
    let title = SessionTitleGenerator.titleFromPrompt("check this slack msg https://example.com/abc it seems broken")
    #expect(title != nil)
    #expect(title!.contains("<url>"))
    #expect(!title!.contains("example.com"))
}

@Test func titleFromPromptReplacesImageWithImagePlaceholder() {
    let title = SessionTitleGenerator.titleFromPrompt("check this chart [Image #1] it looks off")
    #expect(title != nil)
    #expect(title!.contains("<image>"))
    #expect(!title!.contains("[Image"))
}

@Test func titleFromPromptCollapsesLoneImageTag() {
    let title = SessionTitleGenerator.titleFromPrompt("<image name=[Image #1] path=\"/tmp/example.png\">")
    #expect(title == "<image>")
}

@Test func titleFromPromptCollapsesLeadingImageTagAndKeepsText() {
    let title = SessionTitleGenerator.titleFromPrompt("<image name=[Image #1] path=\"/tmp/example.png\"> explain this chart")
    #expect(title == "<image> explain this chart")
}

@Test func titleFromPromptCollapsesUppercaseImageTag() {
    let title = SessionTitleGenerator.titleFromPrompt("<IMAGE name=[Image #1] path=\"/tmp/example.png\"> explain this chart")
    #expect(title == "<image> explain this chart")
}

@Test func titleFromPromptCollapsesImageTagBeforeReplacingURL() {
    let title = SessionTitleGenerator.titleFromPrompt("<image name=[Image #1] path=\"https://example.com/example.png\"> explain this chart")
    #expect(title == "<image> explain this chart")
}

@Test func titleFromPromptKeepsOtherImageLikeTags() {
    let title = SessionTitleGenerator.titleFromPrompt("<image-preview> explain this chart")
    #expect(title == "<image-preview> explain this chart")
}

@Test func titleFromPromptCollapsesLoneBracketAndMarkdownImages() {
    #expect(SessionTitleGenerator.titleFromPrompt("[Image #1]") == "<image>")
    #expect(SessionTitleGenerator.titleFromPrompt("![chart](/tmp/example.png)") == "<image>")
}

@Test func titleFromPromptPreservesLinearIDFromURL() {
    let title = SessionTitleGenerator.titleFromPrompt("fix https://linear.app/acme/issue/ENG-1234/some-slug now")
    #expect(title != nil)
    #expect(title!.contains("ENG-1234"))
    #expect(!title!.contains("linear.app"))
}

@Test func linkedRemainderKeepsMiddleIssueID() {
    #expect(SessionTitleGenerator.linkedTitleRemainder(displayTitle: "Fix ENG-123 bug", issueID: "ENG-123") == "Fix ENG-123 bug")
}

@Test func linkedRemainderDedupesLeadingIssueID() {
    #expect(SessionTitleGenerator.linkedTitleRemainder(displayTitle: "ENG-123 fix bug", issueID: "ENG-123") == "fix bug")
    #expect(SessionTitleGenerator.linkedTitleRemainder(displayTitle: "ENG-123", issueID: "ENG-123") == "")
}
