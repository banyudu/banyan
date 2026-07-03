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
