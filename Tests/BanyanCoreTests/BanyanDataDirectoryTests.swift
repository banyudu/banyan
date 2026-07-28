import Foundation
import Testing
@testable import BanyanCore

@Test func dataDirectoryUsesXDGDataHomeOnLinux() {
    #if os(Linux)
    let home = URL(fileURLWithPath: "/tmp/banyan-home")
    let xdgDataHome = URL(fileURLWithPath: "/tmp/banyan-data")

    #expect(
        BanyanDataDirectory.applicationSupportURL(
            environment: ["XDG_DATA_HOME": xdgDataHome.path],
            homeDirectory: home
        ) == xdgDataHome
    )
    #endif
}

@Test func dataDirectoryFallsBackToLocalShareOnLinux() {
    #if os(Linux)
    let home = URL(fileURLWithPath: "/tmp/banyan-home")

    #expect(
        BanyanDataDirectory.applicationSupportURL(
            environment: [:],
            homeDirectory: home
        ) == home.appendingPathComponent(".local/share")
    )
    #endif
}
