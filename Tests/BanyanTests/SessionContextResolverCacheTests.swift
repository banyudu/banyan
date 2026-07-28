import Foundation
import Testing
@testable import Banyan

private func input(
    sessionID: String = "s1",
    cwd: String = "/Users/example/project",
    title: String,
    titleURL: String? = nil,
    displayTitle: String = ""
) -> SessionContextLookupInput {
    SessionContextLookupInput(
        sessionID: sessionID,
        cwd: cwd,
        title: title,
        titleURL: titleURL,
        displayTitle: displayTitle
    )
}

@Test func cacheKeyIgnoresFreeTextTitleChurn() {
    // Same cwd, no issue/PR tokens — typing in the terminal must not change the key,
    // otherwise every title change re-spawns git/linear/gh.
    let a = SessionContextResolver.cacheKey(for: input(title: "editing foo"))
    let b = SessionContextResolver.cacheKey(for: input(title: "now running tests"))
    #expect(a == b)
}

@Test func cacheKeyTracksIssueToken() {
    let withIssue = SessionContextResolver.cacheKey(for: input(title: "ENG-123 work"))
    let without = SessionContextResolver.cacheKey(for: input(title: "unrelated work"))
    #expect(withIssue != without)
}

@Test func cacheKeyTracksWorkingDirectory() {
    let a = SessionContextResolver.cacheKey(for: input(cwd: "/a", title: "x"))
    let b = SessionContextResolver.cacheKey(for: input(cwd: "/b", title: "x"))
    #expect(a != b)
}

@Test func resolveFastExtractsIssueWithoutSubprocess() {
    let info = SessionContextResolver.resolveFast(input: input(title: "ENG-123 fix"))
    #expect(info.linearIssueID == "ENG-123")
    #expect(info.linearIssueURL != nil)
    #expect(info.linearIssueTitle == nil) // network field stays unset in the fast path
}

@Test func resolveFastExtractsExplicitPullRequestURL() {
    let url = "https://github.com/banyudu/banyan/pull/7"
    let info = SessionContextResolver.resolveFast(input: input(title: "see \(url)"))
    #expect(info.pullRequestURL == url)
    #expect(info.pullRequestNumber == 7)
}

@Test func resolveFastExtractsGitHubIssueWithoutLinearContext() {
    let url = "https://github.com/banyudu/banyan/issues/17"
    let info = SessionContextResolver.resolveFast(input: input(title: "see " + url))
    #expect(info.githubIssueURL == url)
    #expect(info.githubIssueNumber == 17)
    #expect(info.linearIssueID == nil)
}

@Test func githubIssueClientDecodesIssueContentAndMetadata() throws {
    let data = Data(#"{"url":"https://github.com/banyudu/banyan/issues/17","number":17,"title":"Display issues","body":"Details","state":"OPEN","author":{"login":"yudu"},"labels":[{"name":"bug"}],"assignees":[{"login":"yudu"}],"milestone":{"title":"v1"},"comments":[{"id":1,"body":"Looks good","author":{"login":"reviewer"},"createdAt":"2026-07-28T00:00:00Z"}],"createdAt":"2026-07-27T00:00:00Z","updatedAt":"2026-07-28T00:00:00Z"}"#.utf8)
    let issue = try GitHubIssueClient.decodeDetails(data)
    #expect(issue.number == 17)
    #expect(issue.title == "Display issues")
    #expect(issue.body == "Details")
    #expect(issue.labels == ["bug"])
    #expect(issue.comments.first?.body == "Looks good")
}

@Test func reidentifiedPreservesNetworkFields() {
    let original = SessionContextInfo(
        sessionID: "old",
        signature: "sig-old",
        linearIssueID: "ENG-1",
        linearIssueTitle: "Title",
        linearIssueURL: "https://linear.app/x",
        githubIssueNumber: nil,
        githubIssueTitle: nil,
        githubIssueURL: nil,
        pullRequestNumber: 7,
        pullRequestTitle: "PR",
        pullRequestURL: "https://github.com/x/y/pull/7"
    )
    let restamped = original.reidentified(sessionID: "new", signature: "sig-new")
    #expect(restamped.sessionID == "new")
    #expect(restamped.signature == "sig-new")
    #expect(restamped.linearIssueTitle == "Title")
    #expect(restamped.pullRequestNumber == 7)
}
