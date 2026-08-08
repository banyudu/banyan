import Foundation
import Testing
@testable import BanyanCore

@Test func homeDirectoryDisplaysAsTilde() {
    #expect(PathDisplayName.make(path: "/Users/example", homeDirectory: "/Users/example") == "~")
}

@Test func homeSubdirectoryDisplaysWithTildePrefix() {
    #expect(
        PathDisplayName.make(
            path: "/Users/example/dev/yudu/banyan",
            homeDirectory: "/Users/example"
        ) == "~/dev/yudu/banyan"
    )
}

@Test func nonHomePathDisplaysAsAbsolutePath() {
    #expect(PathDisplayName.make(path: "/tmp/banyan", homeDirectory: "/Users/example") == "/tmp/banyan")
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
