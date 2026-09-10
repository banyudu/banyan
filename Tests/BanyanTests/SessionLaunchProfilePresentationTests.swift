@testable import Banyan
import Testing

@Test func configuredLaunchProfilesRemainDistinctForSidebarPresentation() throws {
    let profiles = try SessionLaunchProfileLoader.parse("""
    session_launches:
      - id: codex
        label: Codex
        provider: codex
        command: codex
      - id: luna
        label: Luna
        provider: codex
        icon: ~/.banyan/icons/luna.svg
        command: codex -p luna-fast
    """)

    let luna = profiles.first { $0.command == "codex -p luna-fast" }

    #expect(luna?.id == "luna")
    #expect(luna?.iconName == "~/.banyan/icons/luna.svg")
    #expect(luna?.provider == .codex)
}

@Test func siblingLaunchPreservesConfiguredProfileCommand() throws {
    let profiles = try SessionLaunchProfileLoader.parse("""
    session_launches:
      - id: codex
        label: Codex
        provider: codex
        command: codex
      - id: luna
        label: Luna
        provider: codex
        command: codex -p luna-fast
    """)

    let command = NewSessionLaunch.siblingCommand(
        sessionCommand: "codex -p luna-fast",
        provider: .codex,
        profiles: profiles,
        codexLaunchMode: .direct
    )

    #expect(command == "codex -p luna-fast")
}

/// Guards the sidebar rule that a plain-shell profile must not hide an agent
/// detected inside the session. Every session started from a shell has an
/// empty command and therefore matches the `zsh` profile; that match must not
/// brand the row once `opencode`/`claude`/etc. is running in it.
@Test func plainShellProfileHasNoIconIdentity() {
    let shellProfile = NewSessionLaunch(
        id: "zsh",
        label: "zsh",
        providerName: nil,
        iconName: nil,
        command: ""
    )
    #expect(shellProfile.hasIconIdentity == false)

    let providerProfile = NewSessionLaunch(
        id: "codex",
        label: "Codex",
        providerName: "codex",
        iconName: nil,
        command: "codex"
    )
    #expect(providerProfile.hasIconIdentity)

    let symbolProfile = NewSessionLaunch(
        id: "wrapper",
        label: "Wrapper",
        providerName: nil,
        iconName: "sparkle",
        command: "wrap"
    )
    #expect(symbolProfile.hasIconIdentity)

    let emptyIconProfile = NewSessionLaunch(
        id: "empty-icon",
        label: "Empty",
        providerName: nil,
        iconName: "",
        command: "shell"
    )
    #expect(emptyIconProfile.hasIconIdentity == false)
}
