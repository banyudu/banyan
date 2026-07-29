import Testing
import BanyanCore
@testable import Banyan

@Test func defaultDirectoryTitleTracksCurrentDirectory() {
    #expect(SessionInputPolicy.titleTracksCurrentDirectory(
        "/Users/example/project",
        isTitlePinned: false,
        cwd: "/Users/example/project",
        homeDirectory: "/Users/example"
    ))
}

@Test func pinnedDirectoryTitleDoesNotTrackCurrentDirectory() {
    #expect(!SessionInputPolicy.titleTracksCurrentDirectory(
        "/Users/example/project",
        isTitlePinned: true,
        cwd: "/Users/example/project",
        homeDirectory: "/Users/example"
    ))
}

@Test func customUnpinnedTitleDoesNotTrackCurrentDirectory() {
    #expect(!SessionInputPolicy.titleTracksCurrentDirectory(
        "build logs",
        isTitlePinned: false,
        cwd: "/Users/example/project",
        homeDirectory: "/Users/example"
    ))
}
