@testable import Banyan
import BanyanCore
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

/// Guards the DeepSeek-in-Codex case: the supervisor only sees the `codex`
/// executable, so without the profile's identity the row would brand a
/// DeepSeek session with Codex's icon and tint.
@Test func deepSeekProfileUnderCodexKeepsItsOwnBrand() {
    let profile = NewSessionLaunch(
        id: "deepseek-via-codex",
        label: "DeepSeek (Codex)",
        providerName: "deepseek",
        iconName: nil,
        command: "codex -p deepseek-proxy"
    )

    let branding = NewSessionLaunch.brandingProvider(for: profile, detectedProvider: .codex)

    #expect(branding == .deepseek)
    #expect(branding?.brandTint != CodingAgentProvider.codex.brandTint)
}

/// A provider-less profile must not shadow the runtime: the `zsh` profile
/// matches every empty-command session, and a wrapper that only declares an
/// icon says nothing about the agent either.
@Test func providerlessProfilesFallBackToTheDetectedRuntime() {
    let shellProfile = NewSessionLaunch(
        id: "zsh",
        label: "zsh",
        providerName: nil,
        iconName: nil,
        command: ""
    )
    #expect(NewSessionLaunch.brandingProvider(for: shellProfile, detectedProvider: .claude) == .claude)

    let symbolProfile = NewSessionLaunch(
        id: "wrapper",
        label: "Wrapper",
        providerName: nil,
        iconName: "sparkle",
        command: "wrap"
    )
    #expect(NewSessionLaunch.brandingProvider(for: symbolProfile, detectedProvider: .opencode) == .opencode)
}

@Test func unlaunchedSessionsAndExitedAgentsCarryNoBrand() {
    #expect(NewSessionLaunch.brandingProvider(for: nil, detectedProvider: .codex) == .codex)
    #expect(NewSessionLaunch.brandingProvider(for: nil, detectedProvider: nil) == nil)

    let profile = NewSessionLaunch(
        id: "codex",
        label: "Codex",
        providerName: "codex",
        iconName: nil,
        command: "codex"
    )
    // `displayAgentProvider` drops to nil once the agent exits back to a shell,
    // so the row must stop being branded even though the profile still matches.
    #expect(NewSessionLaunch.brandingProvider(for: profile, detectedProvider: nil) == nil)
}
