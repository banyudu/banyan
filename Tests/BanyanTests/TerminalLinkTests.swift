import Foundation
import Testing
@testable import Banyan

@MainActor
@Test func terminalLinkURLTurnsAbsolutePathIntoFileURL() {
    let url = BanyanSession.terminalLinkURL("/Users/example/math-worksheets/worksheet.pdf")

    #expect(url == URL(fileURLWithPath: "/Users/example/math-worksheets/worksheet.pdf"))
    #expect(url?.isFileURL == true)
}

@MainActor
@Test func terminalLinkURLAcceptsWebURLsButRejectsRelativePaths() {
    #expect(BanyanSession.terminalLinkURL("https://example.com/path")?.absoluteString == "https://example.com/path")
    #expect(BanyanSession.terminalLinkURL("notes/worksheet.pdf") == nil)
}

@MainActor
@Test func referenceNumberReadsBareHashReferences() {
    #expect(BanyanSession.referenceNumber(in: "#9326") == 9326)
    #expect(BanyanSession.referenceNumber(in: "  #123  ") == 123)
    #expect(BanyanSession.referenceNumber(in: "#") == nil)
    #expect(BanyanSession.referenceNumber(in: "#12a") == nil)
    #expect(BanyanSession.referenceNumber(in: "#+12") == nil)
    #expect(BanyanSession.referenceNumber(in: "https://github.com/example/repo/pull/1") == nil)
}

@MainActor
@Test func repositoryReferenceURLUsesTheGitHubRemote() {
    let url = BanyanSession.repositoryReferenceURL(number: 9326, groupID: "git:github.com/example/repo")

    #expect(url?.absoluteString == "https://github.com/example/repo/issues/9326")
    #expect(BanyanSession.repositoryReferenceURL(number: 1, groupID: "git:gitlab.com/example/repo") == nil)
    #expect(BanyanSession.repositoryReferenceURL(number: 1, groupID: "path:/tmp/example") == nil)
}
