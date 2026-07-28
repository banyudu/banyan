import Testing
@testable import BanyanCore

@Test func hostExecutablePathsIncludeUsableSystemDirectories() {
    let paths = HostExecutablePaths.systemPaths()

    #expect(!paths.isEmpty)
    #expect(paths.allSatisfy { $0.hasSuffix("/bin") })
    #expect(Set(paths).count == paths.count)
}

@Test func hostExecutablePathsBuildUserDirectoriesFromHome() {
    #expect(
        HostExecutablePaths.userPaths(homeDirectory: "/tmp/banyan-home") == [
            "/tmp/banyan-home/bin",
            "/tmp/banyan-home/.bun/bin",
            "/tmp/banyan-home/.local/bin",
            "/tmp/banyan-home/.cargo/bin",
            "/tmp/banyan-home/go/bin",
            "/tmp/banyan-home/.nix-profile/bin"
        ]
    )
}

@Test func hostExecutablePathsUsePlatformOrdering() {
    #if os(macOS)
    #expect(HostExecutablePaths.systemPaths().first == "/opt/homebrew/bin")
    #else
    #expect(HostExecutablePaths.systemPaths().first == "/usr/local/bin")
    #endif
}
