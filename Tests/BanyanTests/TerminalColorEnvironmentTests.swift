import BanyanCore
import Foundation
import Testing
@testable import Banyan

@MainActor
@Test(arguments: [nil, "", "1"] as [String?])
func terminalAttachEnvironmentIgnoresLauncherColorFlags(noColor: String?) {
    var inherited = ["PATH": "/usr/bin:/bin", "SHELL": "/bin/sh", "TMPDIR": "/tmp", "SSH_AUTH_SOCK": "/tmp/test-agent.sock"]
    inherited["NO_COLOR"] = noColor
    inherited["FORCE_COLOR"] = "3"
    inherited["CLICOLOR_FORCE"] = "1"
    let session = TerminalSession(
        id: "color-environment",
        title: "Color environment",
        cwd: "/tmp",
        command: "",
        theme: .system,
        tmuxBackend: banyanTestTmuxBackend,
        telemetry: banyanTestTelemetry,
        host: HostRuntimeContext(
            environment: inherited,
            homeDirectory: URL(fileURLWithPath: "/tmp"),
            currentDirectory: "/tmp"
        )
    )

    let environment = session.terminalEnvironment()

    #expect(!environment.contains { $0.hasPrefix("CLICOLOR_FORCE=") || $0.hasPrefix("FORCE_COLOR=") })
    #expect(environment.contains("TERM=\(TmuxBackend.attachTermName)"))
    #expect(environment.contains("COLORTERM=truecolor"))
    #expect(environment.contains("CLICOLOR=1"))
    for (key, value) in inherited where !["NO_COLOR", "FORCE_COLOR", "CLICOLOR_FORCE"].contains(key) {
        #expect(environment.contains("\(key)=\(value)"))
    }
    #expect(!environment.contains { $0.hasPrefix("NO_COLOR=") })
    #expect(session.loadedTerminalView == nil)
}
