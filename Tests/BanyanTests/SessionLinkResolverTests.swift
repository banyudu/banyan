import Foundation
import Testing
@testable import Banyan

struct SessionLinkResolverTests {
    @Test func terminalAndNativeReferencesResolveToTheSameRepository() async throws {
        let cache = GitHubReferenceCache()
        let group = "git:github.com/example/repo"
        let expected = try #require(URL(string: "https://github.com/example/repo/pull/123"))
        cache.store(.resolved(expected), groupID: group, number: 123)
        let context = SessionLinkContext(cwd: "/tmp", environment: [:], homeDirectory: "/tmp",
                                         repositoryGroupID: group, cache: cache)
        let nativeURL = try #require(SessionLinkResolver.referenceURL("#123", environment: [:]))
        #expect(await SessionLinkResolver.resolve(.reference("#123"), context: context) == expected)
        #expect(await SessionLinkResolver.resolve(.url(nativeURL), context: context) == expected)

        let otherGroup = "git:github.com/example/other"
        cache.store(.missing, groupID: otherGroup, number: 123)
        let otherContext = SessionLinkContext(cwd: "/tmp", environment: [:], homeDirectory: "/tmp",
                                              repositoryGroupID: otherGroup, cache: cache)
        #expect(await SessionLinkResolver.resolve(.url(nativeURL), context: otherContext) == nil)
    }

    @Test func filesResolveAgainstTheSessionAndPreserveExplicitMarkdownDestinations() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("session-links-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("report notes.md")
        let issueNamedFile = root.appendingPathComponent("TASK-123")
        try Data().write(to: file)
        try Data().write(to: issueNamedFile)
        let context = SessionLinkContext(cwd: root.path, environment: ["BANYAN_LINEAR_ORG": "example"],
                                         homeDirectory: root.path)

        for path in [file.path, "./report notes.md", "~/report notes.md"] {
            let nativeURL = try #require(SessionLinkResolver.referenceURL(path, environment: context.environment))
            #expect(await SessionLinkResolver.resolve(.reference(path), context: context) == file)
            #expect(await SessionLinkResolver.resolve(.url(nativeURL), context: context) == file)
        }
        let relative = try #require(URL(string: "report%20notes.md"))
        #expect(await SessionLinkResolver.resolve(.url(relative), context: context) == file)
        let explicit = try #require(URL(string: "TASK-123"))
        #expect(await SessionLinkResolver.resolve(.url(explicit), context: context) == issueNamedFile)
        #expect(await SessionLinkResolver.resolve(.reference("TASK-123"), context: context)?.absoluteString
            == "https://linear.app/example/issue/TASK-123")
        #expect(await SessionLinkResolver.resolve(.reference("./missing.txt"), context: context) == nil)
    }

    @Test func explicitURLsStayIntactAndUnsupportedSchemesDoNotOpen() async throws {
        let context = SessionLinkContext(cwd: "/tmp", environment: [:], homeDirectory: "/tmp")
        let url = try #require(URL(string: "https://example.com/TASK-123?q=a%20b#456"))
        #expect(await SessionLinkResolver.resolve(.url(url), context: context) == url)
        #expect(await SessionLinkResolver.resolve(.reference(url.absoluteString), context: context) == url)
        for value in ["javascript:alert(1)", "banyan-session-reference://wrong?text=%23123"] {
            let supplied = try #require(URL(string: value))
            #expect(await SessionLinkResolver.resolve(.url(supplied), context: context) == nil)
        }
    }
}
