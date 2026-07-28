import Foundation
import BanyanCore
import Testing
@testable import Banyan

@Test func shellEnvironmentParserIgnoresOutputBeforeMarker() {
    let output = Data("startup noise\n__BANYAN_SHELL_ENV_START__\nLINEAR_API_KEY=from-shell\0EMPTY=\0PATH=/one:/two\0".utf8)

    let environment = AppProcessEnvironment.parseEnvironmentOutput(output)

    #expect(environment["LINEAR_API_KEY"] == "from-shell")
    #expect(environment["EMPTY"] == "")
    #expect(environment["PATH"] == "/one:/two")
}

@Test func shellEnvironmentMergeUsesAllowlistAndPreservesExistingValues() {
    var environment = [
        "LINEAR_API_KEY": "from-app"
    ]
    let shellEnvironment = [
        "LINEAR_API_KEY": "from-shell",
        "GITHUB_TOKEN": "github-from-shell",
        "UNLISTED_SECRET": "do-not-import"
    ]

    AppProcessEnvironment.mergeAllowedShellEnvironment(
        shellEnvironment,
        into: &environment,
        allowlist: ["LINEAR_API_KEY", "GITHUB_TOKEN"]
    )

    #expect(environment["LINEAR_API_KEY"] == "from-app")
    #expect(environment["GITHUB_TOKEN"] == "github-from-shell")
    #expect(environment["UNLISTED_SECRET"] == nil)
}

@Test func shellEnvironmentMergeAcceptsConfiguredAllowlistFromShell() {
    var environment: [String: String] = [:]
    let shellEnvironment = [
        "BANYAN_SHELL_ENV_ALLOWLIST": "CUSTOM_TOKEN,SECOND_TOKEN",
        "CUSTOM_TOKEN": "custom",
        "SECOND_TOKEN": "second"
    ]

    AppProcessEnvironment.mergeAllowedShellEnvironment(shellEnvironment, into: &environment)

    #expect(environment["CUSTOM_TOKEN"] == "custom")
    #expect(environment["SECOND_TOKEN"] == "second")
}

@Test func shellEnvironmentPathMergeDeduplicatesKnownShellAndCurrentPaths() {
    var environment = [
        "PATH": "/usr/bin:/bin"
    ]

    AppProcessEnvironment.mergePath(
        into: &environment,
        pathAdditions: ["/opt/homebrew/bin", "/usr/bin"],
        shellPath: "/Users/example/bin:/opt/homebrew/bin"
    )

    #expect(environment["PATH"] == "/opt/homebrew/bin:/usr/bin:/Users/example/bin:/bin")
}
