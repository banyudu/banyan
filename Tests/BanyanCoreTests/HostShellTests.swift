import Testing
@testable import BanyanCore

@Test func hostShellUsesConfiguredShell() {
    #expect(HostShell.executablePath(environment: ["SHELL": "/custom/bin/fish"]) == "/custom/bin/fish")
    #expect(HostShell.executablePath(environment: ["SHELL": "  /custom/bin/bash  "]) == "/custom/bin/bash")
}

@Test func hostShellUsesPlatformFallbackWhenUnset() {
    #if os(macOS)
    #expect(HostShell.executablePath(environment: [:]) == "/bin/zsh")
    #else
    #expect(HostShell.executablePath(environment: [:]) == "/bin/sh")
    #endif
}
