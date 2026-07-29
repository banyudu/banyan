import Testing
@testable import Banyan

@Test func defaultDirectoryTitleTracksCurrentDirectory() {
    #expect(BanyanSession.titleTracksCurrentDirectory(
        "/Users/example/project",
        isTitlePinned: false,
        cwd: "/Users/example/project",
        homeDirectory: "/Users/example"
    ))
}

@Test func pinnedDirectoryTitleDoesNotTrackCurrentDirectory() {
    #expect(!BanyanSession.titleTracksCurrentDirectory(
        "/Users/example/project",
        isTitlePinned: true,
        cwd: "/Users/example/project",
        homeDirectory: "/Users/example"
    ))
}

@Test func customUnpinnedTitleDoesNotTrackCurrentDirectory() {
    #expect(!BanyanSession.titleTracksCurrentDirectory(
        "build logs",
        isTitlePinned: false,
        cwd: "/Users/example/project",
        homeDirectory: "/Users/example"
    ))
}
