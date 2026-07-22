import Foundation
import Testing
@testable import BanyanCore

@Test func homeDirectoryDisplaysAsTilde() {
    #expect(PathDisplayName.make(path: "/Users/banyudu", homeDirectory: "/Users/banyudu") == "~")
}

@Test func homeSubdirectoryDisplaysWithTildePrefix() {
    #expect(
        PathDisplayName.make(
            path: "/Users/banyudu/dev/yudu/banyan",
            homeDirectory: "/Users/banyudu"
        ) == "~/dev/yudu/banyan"
    )
}

@Test func nonHomePathDisplaysAsAbsolutePath() {
    #expect(PathDisplayName.make(path: "/tmp/banyan", homeDirectory: "/Users/banyudu") == "/tmp/banyan")
}

@Test func symlinkedHomePathDisplaysUsingCanonicalTildePath() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("BanyanPathDisplay-\(UUID().uuidString)")
    let realDirectory = root.appendingPathComponent("real")
    let alias = root.appendingPathComponent("alias")
    defer { try? FileManager.default.removeItem(at: root) }

    try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: realDirectory)

    #expect(PathDisplayName.make(path: alias.path, homeDirectory: root.path) == "~/real")
    #expect(PathDisplayName.canonicalPath(alias.path) == realDirectory.path)
}
