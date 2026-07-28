import Testing

@testable import BanyanCore

@Test func githubIssueReferenceDetectsURL() {
    let reference = GitHubIssueReference.detect(in: "https://github.com/banyudu/banyan/issues/19")
    #expect(reference?.number == 19)
}

@Test func githubIssueReferenceDetectsBranchOnGitHubRemote() {
    let reference = GitHubIssueReference.detect(
        branch: "yudu/19-make-linear-acceptance-criteria-checkboxes-interactive",
        remoteAddress: "github.com/banyudu/banyan"
    )
    #expect(reference?.url == "https://github.com/banyudu/banyan/issues/19")
}

@Test func githubIssueReferenceRespectsTrackerOverride() {
    #expect(GitHubIssueReference.detect(
        branch: "yudu/19-feature",
        remoteAddress: "github.com/banyudu/banyan",
        issueTracker: "linear"
    ) == nil)
}
