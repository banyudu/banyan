@testable import Banyan
import Foundation
import Testing

@Test func commandPaletteRecognizesLinearIssueIdentifiers() {
    #expect(CommandPaletteTargetResolver.linearIssueID(in: "ENG-123") == "ENG-123")
    #expect(CommandPaletteTargetResolver.linearIssueID(in: "open ENG-123") == "ENG-123")
    #expect(CommandPaletteTargetResolver.linearIssueID(in: "not-an-issue") == nil)
}

@Test func commandPaletteBuildsGitHubPullRequestURLFromRepositoryReference() {
    let url = CommandPaletteTargetResolver.pullRequestURL(
        in: "banyudu/banyan#456",
        fallback: nil
    )
    #expect(url?.absoluteString == "https://github.com/banyudu/banyan/pull/456")
}

@Test func commandPaletteUsesSelectedRepositoryForBarePullRequestNumber() {
    let fallback = URL(string: "https://github.com/banyudu/banyan/pull/16")
    let url = CommandPaletteTargetResolver.pullRequestURL(in: "#456", fallback: fallback)
    #expect(url?.absoluteString == "https://github.com/banyudu/banyan/pull/456")
}

@Test func commandPaletteAcceptsGitHubPullRequestURL() {
    let url = CommandPaletteTargetResolver.pullRequestURL(
        in: "https://github.com/banyudu/banyan/pull/456",
        fallback: nil
    )
    #expect(url?.absoluteString == "https://github.com/banyudu/banyan/pull/456")
}

@Test func commandPaletteRejectsInvalidPullRequestTargets() {
    #expect(CommandPaletteTargetResolver.pullRequestURL(in: "#0", fallback: nil) == nil)
    #expect(CommandPaletteTargetResolver.pullRequestURL(in: "banyudu/banyan", fallback: nil) == nil)
    #expect(CommandPaletteTargetResolver.pullRequestURL(in: "https://example.com/pr/1", fallback: nil) == nil)
}
