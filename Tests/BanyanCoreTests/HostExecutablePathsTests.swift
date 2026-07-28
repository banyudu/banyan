import Testing
@testable import BanyanCore

@Test func hostExecutablePathsIncludeUsableSystemDirectories() {
    let paths = HostExecutablePaths.systemPaths()

    #expect(!paths.isEmpty)
    #expect(paths.allSatisfy { $0.hasSuffix("/bin") })
    #expect(Set(paths).count == paths.count)
}

@Test func hostExecutablePathsUsePlatformOrdering() {
    #if os(macOS)
    #expect(HostExecutablePaths.systemPaths().first == "/opt/homebrew/bin")
    #else
    #expect(HostExecutablePaths.systemPaths().first == "/usr/local/bin")
    #endif
}
