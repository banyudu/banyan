import BanyanCore
import Testing

@Test func linearIssueReferenceDetectsBranchPatternInAWorktree() {
    let reference = LinearIssueReference.detect(
        branch: "yudu/eng-6772-fix-scroll",
        cwd: "/Users/example/dev/yudu/.worktrees/scroll",
        isGitWorktree: true,
        environment: [:]
    )

    #expect(reference?.id == "ENG-6772")
    #expect(reference?.url == "https://linear.app/2en/issue/ENG-6772")
}

@Test func linearIssueReferenceIgnoresTheBranchOfTheMainCheckout() {
    // The main checkout is shared by every session opened in the project, so a
    // throwaway `git checkout` there must not bind them all to that issue.
    #expect(LinearIssueReference.detect(
        branch: "yudu/eng-6772-fix-scroll",
        cwd: "/Users/example/dev/yudu/banyan",
        isGitWorktree: false,
        environment: [:]
    ) == nil)
}

@Test func linearIssueReferenceStillReadsTheMainCheckoutDirectory() {
    // A directory name is per-session and cannot drift under other panes.
    let reference = LinearIssueReference.detect(
        branch: "main",
        cwd: "/Users/example/dev/yudu/eng-1234-spike",
        isGitWorktree: false,
        environment: [:]
    )

    #expect(reference?.id == "ENG-1234")
}

@Test func linearIssueReferenceFallsBackToWorkingDirectory() {
    let reference = LinearIssueReference.detect(
        branch: nil,
        cwd: "/Users/example/dev/yudu/.worktrees/yudu-eng-1234",
        isGitWorktree: true,
        environment: [:]
    )

    #expect(reference?.id == "ENG-1234")
}

@Test func linearIssueReferenceFallsBackToWorktreeDirectoryOnDetachedHEAD() {
    let reference = LinearIssueReference.detect(
        branch: "a1b2c3d",
        cwd: "/Users/example/dev/yudu/.worktrees/yudu-eng-1234",
        isGitWorktree: true,
        environment: [:]
    )

    #expect(reference?.id == "ENG-1234")
}

@Test func linearIssueReferenceTreatsAWorktreeBranchWithoutAnIssueAsNoIssue() {
    #expect(LinearIssueReference.detect(
        branch: "yudu/spike",
        cwd: "/Users/example/dev/yudu/.worktrees/yudu-eng-1234",
        isGitWorktree: true,
        environment: [:]
    ) == nil)
}

@Test func linearIssueReferencePrefersExplicitURLThenTitleThenContext() {
    #expect(LinearIssueReference.preferredID(
        titleURL: "https://linear.app/2en/issue/ENG-9",
        title: "ENG-8 task",
        branch: "eng-7-task",
        cwd: "/tmp/ENG-6",
        isGitWorktree: true,
        environment: [:]
    ) == "ENG-9")
    #expect(LinearIssueReference.preferredID(
        titleURL: nil,
        title: "ENG-8 task",
        branch: "eng-7-task",
        cwd: "/tmp/ENG-6",
        isGitWorktree: true,
        environment: [:]
    ) == "ENG-8")
    #expect(LinearIssueReference.preferredID(
        titleURL: nil,
        title: nil,
        branch: "eng-7-task",
        cwd: "/tmp/ENG-6",
        isGitWorktree: true,
        environment: [:]
    ) == "ENG-7")
}

@Test func linearIssueReferenceRejectsNonIssueText() {
    #expect(LinearIssueReference.issueID(in: "release-2026-07-06") == nil)
    #expect(LinearIssueReference.issueID(in: "engineering-notes") == nil)
}

@Test func githubIssueReferenceDetectsIssueURL() {
    let reference = GitHubIssueReference.detect(in: "Fix https://github.com/banyudu/banyan/issues/17")
    #expect(reference?.url == "https://github.com/banyudu/banyan/issues/17")
    #expect(reference?.number == 17)
}

@Test func githubIssueReferenceDoesNotTreatPullRequestAsIssue() {
    #expect(GitHubIssueReference.detect(in: "https://github.com/banyudu/banyan/pull/17") == nil)
}

@Test func githubIssueReferenceDetectsFromBranchAndRemote() {
    let ref = GitHubIssueReference.detect(
        branch: "yudu/17-add-support-for-feature",
        remoteAddress: "github.com/banyudu/banyan"
    )
    #expect(ref?.url == "https://github.com/banyudu/banyan/issues/17")
    #expect(ref?.number == 17)
}

@Test func githubIssueReferenceIgnoresNonGitHubRemote() {
    #expect(GitHubIssueReference.detect(
        branch: "yudu/17-feature",
        remoteAddress: "gitlab.com/banyudu/banyan"
    ) == nil)
}

@Test func githubIssueReferenceIgnoresBranchWithoutIssueNumber() {
    #expect(GitHubIssueReference.detect(
        branch: "main",
        remoteAddress: "github.com/banyudu/banyan"
    ) == nil)
    #expect(GitHubIssueReference.detect(
        branch: "feature/redesign",
        remoteAddress: "github.com/banyudu/banyan"
    ) == nil)
}

@Test func githubIssueReferenceIgnoresVersionBranches() {
    #expect(GitHubIssueReference.detect(
        branch: "release/2-0-0",
        remoteAddress: "github.com/banyudu/banyan"
    ) == nil)
}
