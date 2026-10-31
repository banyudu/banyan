import Foundation
import Testing
@testable import Banyan

@MainActor
@Test func terminalLinkURLTurnsAbsolutePathIntoFileURL() {
    let url = TerminalSession.terminalLinkURL("/Users/example/math-worksheets/worksheet.pdf")

    #expect(url == URL(fileURLWithPath: "/Users/example/math-worksheets/worksheet.pdf"))
    #expect(url?.isFileURL == true)
}

@MainActor
@Test func terminalLinkURLResolvesRelativePathsAgainstTheTerminalDirectory() {
    let url = TerminalSession.terminalLinkURL(
        "docs/design/diagrams/puck-boundary.svg",
        relativeTo: "/Users/example/project"
    )

    #expect(url == URL(fileURLWithPath: "/Users/example/project/docs/design/diagrams/puck-boundary.svg"))
    #expect(url?.isFileURL == true)
}

@MainActor
@Test func terminalLinkURLNormalizesRelativePathComponents() {
    let url = TerminalSession.terminalLinkURL("../README.md", relativeTo: "/Users/example/project/docs")

    #expect(url == URL(fileURLWithPath: "/Users/example/project/README.md"))
}

@MainActor
@Test func terminalLinkURLAcceptsWebURLsWithoutUsingTheTerminalDirectory() {
    #expect(TerminalSession.terminalLinkURL("https://example.com/path")?.absoluteString == "https://example.com/path")
    #expect(TerminalSession.terminalLinkURL("https://example.com/path", relativeTo: "/Users/example/project")?.absoluteString == "https://example.com/path")
}

@MainActor
@Test func terminalLinkURLRejectsRelativePathsWithoutADirectoryToResolveAgainst() {
    #expect(TerminalSession.terminalLinkURL("notes/worksheet.pdf") == nil)
}

@MainActor
@Test func referenceNumberReadsBareHashReferences() {
    #expect(TerminalSession.referenceNumber(in: "#9326") == 9326)
    #expect(TerminalSession.referenceNumber(in: "  #123  ") == 123)
    #expect(TerminalSession.referenceNumber(in: "#") == nil)
    #expect(TerminalSession.referenceNumber(in: "#12a") == nil)
    #expect(TerminalSession.referenceNumber(in: "#+12") == nil)
    #expect(TerminalSession.referenceNumber(in: "https://github.com/example/repo/pull/1") == nil)
}

@MainActor
@Test func repositoryReferenceURLUsesTheGitHubRemote() {
    let url = GitHubReferenceResolver.repositoryURL(number: 9326, groupID: "git:github.com/example/repo")

    #expect(url?.absoluteString == "https://github.com/example/repo/issues/9326")
    #expect(GitHubReferenceResolver.repositoryURL(number: 1, groupID: "git:gitlab.com/example/repo") == nil)
    #expect(GitHubReferenceResolver.repositoryURL(number: 1, groupID: "path:/tmp/example") == nil)
}

/// `gh` phrasing for "this repository has no such number". It must be told
/// apart from failures to run at all, because only the former means a
/// repository URL would definitely 404.
@Test func referenceLookupReadsGraphQLResolveFailuresAsNotFound() {
    #expect(GitHubReferenceResolver.isNotFound(
        message: "GraphQL: Could not resolve to a PullRequest with the number of 9326. (repository.pullRequest)"
    ))
    #expect(GitHubReferenceResolver.isNotFound(
        message: "GraphQL: Could not resolve to an issue or pull request with the number of 99999. (repository.issue)"
    ))

    #expect(!GitHubReferenceResolver.isNotFound(message: "failed to run git: fatal: not a git repository"))
    #expect(!GitHubReferenceResolver.isNotFound(message: "dial tcp: lookup api.github.com: no such host"))
    #expect(!GitHubReferenceResolver.isNotFound(message: nil))
}
