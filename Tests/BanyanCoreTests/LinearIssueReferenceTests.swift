import BanyanCore
import Testing

@Test func linearIssueReferenceDetectsBranchPattern() {
    let reference = LinearIssueReference.detect(
        branch: "yudu/eng-6772-fix-scroll",
        cwd: "/Users/banyudu/dev/yudu/banyan"
    )

    #expect(reference?.id == "ENG-6772")
    #expect(reference?.url == "https://linear.app/2en/issue/ENG-6772")
}

@Test func linearIssueReferenceFallsBackToWorkingDirectory() {
    let reference = LinearIssueReference.detect(
        branch: nil,
        cwd: "/Users/banyudu/dev/yudu/.worktrees/yudu-eng-1234"
    )

    #expect(reference?.id == "ENG-1234")
}

@Test func linearIssueReferenceRejectsNonIssueText() {
    #expect(LinearIssueReference.issueID(in: "release-2026-07-06") == nil)
    #expect(LinearIssueReference.issueID(in: "engineering-notes") == nil)
}
