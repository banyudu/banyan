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

@Test func resolveFastExtractsExplicitGitHubIssueURL() {
    let url = "https://github.com/banyudu/banyan/issues/19"
    let info = SessionContextResolver.resolveFast(input: input(title: url))
    #expect(info.githubIssueURL == url)
    #expect(info.githubIssueNumber == 19)
    #expect(info.linearIssueID == nil)
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
