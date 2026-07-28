import Foundation
import Testing
@testable import BanyanCore

@Test func sharedEnvironmentBuilderParsesShellOutput() {
    let bytes = Array("\n__BANYAN_SHELL_ENV_START__\nFOO=bar\0PATH=/custom/bin\0".utf8)

    #expect(
        AppProcessEnvironment.parseEnvironmentOutput(Data(bytes)) == [
            "FOO": "bar",
            "PATH": "/custom/bin"
        ]
    )
}

@Test func sharedEnvironmentBuilderDeduplicatesPathEntries() {
    var environment = ["PATH": "/usr/bin:/work/bin"]

    AppProcessEnvironment.mergePath(
        into: &environment,
        pathAdditions: ["/work/bin", "/local/bin"],
        shellPath: "/local/bin:/shell/bin"
    )

    #expect(environment["PATH"] == "/work/bin:/local/bin:/shell/bin:/usr/bin")
}
