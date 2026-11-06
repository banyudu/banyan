import Foundation
import Testing
@testable import Banyan

@Test func markdownInlineLinksEveryIssueInMultilingualProse() {
    let value = "🐳 已找到工单 TASK-123，关联 task-456/TASK-123。"
    let result = MarkdownInlineText.parse(value, environment: ["BANYAN_LINEAR_ORG": "example"])

    #expect(String(result.characters) == value)
    #expect(result.runs.compactMap { $0.link?.absoluteString } == [
        "https://linear.app/example/issue/TASK-123",
        "https://linear.app/example/issue/TASK-456",
        "https://linear.app/example/issue/TASK-123",
    ])
}

@Test func markdownInlineIssueLinksPreserveFormattingAndCustomBaseURL() throws {
    let result = MarkdownInlineText.parse(
        "**TASK-123** and `task-456`",
        environment: [
            "BANYAN_LINEAR_ORG": "unused",
            "BANYAN_LINEAR_BASE_URL": " https://tracker.example.com/issue/ ",
        ]
    )

    #expect(String(result.characters) == "TASK-123 and task-456")
    let bold = try #require(result.runs.first { $0.link?.lastPathComponent == "TASK-123" })
    #expect(bold.inlinePresentationIntent?.contains(.stronglyEmphasized) == true)
    #expect(bold.link?.absoluteString == "https://tracker.example.com/issue/TASK-123")
    let code = try #require(result.runs.first { $0.link?.lastPathComponent == "TASK-456" })
    #expect(code.inlinePresentationIntent?.contains(.code) == true)
    #expect(code.link?.absoluteString == "https://tracker.example.com/issue/TASK-456")
}

@Test func markdownInlineIssueLinksPreserveExplicitLinksAndBareURLs() {
    let result = MarkdownInlineText.parse(
        "[TASK-123](https://example.com/original) <https://example.com/TASK-456> https://example.com/TASK-789",
        environment: ["BANYAN_LINEAR_ORG": "example"]
    )

    #expect(result.runs.compactMap { $0.link?.absoluteString } == [
        "https://example.com/original",
        "https://example.com/TASK-456",
        "https://example.com/TASK-789",
    ])
}

@Test func markdownInlineIssueLinksRespectIdentifierBoundariesAcrossFormatting() {
    let result = MarkdownInlineText.parse(
        "XTASK-123x 1TASK-456 TASK-789z TOOLONG-12 release-2026-11-06 prefix**TASK-123**",
        environment: ["BANYAN_LINEAR_ORG": "example"]
    )

    #expect(result.runs.allSatisfy { $0.link == nil })
}

@Test func markdownInlineIssueLinksLeaveURLsInsideCodeSpansIntact() {
    let result = MarkdownInlineText.parse(
        "`https://example.com/TASK-123` and `TASK-456`",
        environment: ["BANYAN_LINEAR_ORG": "example"]
    )

    #expect(String(result.characters) == "https://example.com/TASK-123 and TASK-456")
    #expect(result.runs.compactMap { $0.link?.absoluteString } == ["https://linear.app/example/issue/TASK-456"])
}
