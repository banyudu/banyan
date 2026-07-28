import Testing
@testable import BanyanCore

@Test func sharedSessionContextResolverProvidesFastIssueContext() {
    let input = SessionContextLookupInput(
        sessionID: "session-1",
        cwd: "/tmp/project",
        homeDirectory: "/home/test",
        environment: [:],
        title: "ENG-123 fix",
        titleURL: nil,
        displayTitle: "ENG-123 fix"
    )

    let result = SessionContextResolver.resolveFast(input: input)

    #expect(result.sessionID == "session-1")
    #expect(result.linearIssueID == "ENG-123")
    #expect(result.linearIssueURL == "https://linear.app/2en/issue/ENG-123")
}

@Test func sharedSessionContextLookupSignatureIncludesDisplayInputs() {
    let first = SessionContextLookupInput(
        sessionID: "session-1",
        cwd: "/tmp/project",
        homeDirectory: "/home/test",
        environment: [:],
        title: "one",
        titleURL: nil,
        displayTitle: "one"
    )
    let second = SessionContextLookupInput(
        sessionID: "session-1",
        cwd: "/tmp/project",
        homeDirectory: "/home/test",
        environment: [:],
        title: "two",
        titleURL: nil,
        displayTitle: "two"
    )

    #expect(first.signature != second.signature)
}
