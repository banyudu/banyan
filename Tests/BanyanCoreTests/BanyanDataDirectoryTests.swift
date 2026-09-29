import Foundation
import Testing
@testable import BanyanCore

@Test func fixtureDataHomeOverridesPlatformDefaultOnlyWhenExplicitAndAbsolute() {
    let home = URL(fileURLWithPath: "/tmp/example-home")
    let fixture = URL(fileURLWithPath: "/tmp/example-fixture")
    let environment = ["BANYAN_FIXTURE_DATA_HOME": fixture.path]
    #expect(BanyanDataDirectory.fixtureDataHome(environment: environment)?.path == fixture.path)
    #expect(BanyanDataDirectory.applicationSupportURL(
        environment: environment, homeDirectory: home).path == fixture.path)
    #expect(SessionDatabase.defaultDatabaseURL(
        environment: environment, homeDirectory: home)
        == fixture.appendingPathComponent("Banyan/state.sqlite"))
    #expect(BanyanDataDirectory.fixtureDataHome(environment: [:]) == nil)
    #expect(BanyanDataDirectory.fixtureDataHome(
        environment: ["BANYAN_FIXTURE_DATA_HOME": "relative/path"]) == nil)
}

@Test func processFixtureDataHomeResolvesInsideTemporaryRoot() {
    let environment = ProcessInfo.processInfo.environment
    guard let expected = environment["BANYAN_FIXTURE_DATA_HOME"] else { return }
    let home = URL(fileURLWithPath: NSHomeDirectory())
    let resolved = SessionDatabase.defaultDatabaseURL(
        environment: environment, homeDirectory: home)
    #expect(resolved.path == URL(fileURLWithPath: expected)
        .appendingPathComponent("Banyan/state.sqlite").path)
}

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
