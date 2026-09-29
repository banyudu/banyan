@testable import Banyan
import Foundation
import Testing

@Test func sessionLaunchProfilesParseLabelsProvidersAndCommands() throws {
    let profiles = try SessionLaunchProfileLoader.parse("""
    session_launches:
      - id: codex-fast
        label: Codex Fast
        provider: codex
        command: codex --profile fast
      - id: claude-opus
        label: Claude Opus
        provider: claude
        icon: ~/.banyan/icons/claude-opus.png
        command: "claude --model opus --dangerously-skip-permissions"
    """)

    #expect(profiles.map(\.id) == ["codex-fast", "claude-opus"])
    #expect(profiles[0].label == "Codex Fast")
    #expect(profiles[0].provider == .codex)
    #expect(profiles[0].command == "codex --profile fast")
    #expect(profiles[0].puck == nil) // A CLI profile may select an unknown model/account.
    #expect(profiles[1].command == "claude --model opus --dangerously-skip-permissions")
    #expect(profiles[1].iconName == "~/.banyan/icons/claude-opus.png")
}

@Test func puckLaunchProfileKeepsExplicitModelAndAccount() throws {
    let profiles = try SessionLaunchProfileLoader.parse("""
    session_launches:
      - id: muse
        label: Muse Spark
        provider: muse
        command: opencode --agent muse-spark
        puck_provider: opencode-go
        puck_model: muse-spark-1.3-contributor
        puck_account: personal
    """)
    #expect(profiles[0].puck == .init(provider: "opencode-go",
                                      model: "muse-spark-1.3-contributor", account: "personal"))
    #expect(NewSessionLaunch.builtInDefaults.first { $0.id == "codex" }?.puck == .init(provider: "codex"))
}

@Test func anthropicPuckProfileRequiresExplicitModelAndAccount() throws {
    let profiles = try SessionLaunchProfileLoader.parse("""
    session_launches:
      - id: claude-api
        label: Claude API
        provider: claude
        command: claude
        puck_provider: anthropic
        puck_model: claude-sonnet-4-6
        puck_account: console-seat
    """)
    #expect(profiles[0].puck == .init(provider: "anthropic",
                                      model: "claude-sonnet-4-6", account: "console-seat"))
    #expect(NewSessionLaunch.builtInDefaults.first { $0.id == "claude" }?.puck == nil)
    #expect(throws: Error.self) {
        try SessionLaunchProfileLoader.parse("""
        session_launches:
          - id: claude-api
            label: Claude API
            command: claude
            puck_provider: anthropic
            puck_model: claude-sonnet-4-6
        """)
    }
}

@Test func geminiPuckProfileRequiresExplicitModelAndAccount() throws {
    let profiles = try SessionLaunchProfileLoader.parse("""
    session_launches:
      - id: gemini-api
        label: Gemini API
        provider: gemini
        command: gemini
        puck_provider: gemini
        puck_model: gemini-2.5-flash
        puck_account: ai-studio-seat
    """)
    #expect(profiles[0].puck == .init(provider: "gemini",
                                      model: "gemini-2.5-flash", account: "ai-studio-seat"))
    #expect(throws: Error.self) {
        try SessionLaunchProfileLoader.parse("""
        session_launches:
          - id: gemini-api
            label: Gemini API
            command: gemini
            puck_provider: gemini
            puck_model: gemini-2.5-flash
        """)
    }
    #expect(throws: Error.self) {
        try SessionLaunchProfileLoader.parse("""
        session_launches:
          - id: gemini-api
            label: Gemini API
            command: gemini
            puck_provider: gemini
            puck_account: ai-studio-seat
        """)
    }
}

@Test func invalidPuckLaunchProfileDoesNotBecomeACLIProfile() {
    #expect(throws: Error.self) {
        try SessionLaunchProfileLoader.parse("""
        session_launches:
          - id: unknown
            label: Unknown
            command: opencode
            puck_provider: another-provider
        """)
    }
    #expect(throws: Error.self) {
        try SessionLaunchProfileLoader.parse("""
        session_launches:
          - id: incomplete
            label: Incomplete
            command: opencode
            puck_model: muse-spark-1.3-contributor
        """)
    }
}

@Test func duplicateSessionLaunchProfileIDsFallBackToDefaults() {
    let url = temporaryConfigURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! """
    session_launches:
      - id: codex
        label: Codex
        command: codex
      - id: codex
        label: Another Codex
        command: codex --profile fast
    """.write(to: url, atomically: true, encoding: .utf8)

    let result = SessionLaunchProfileLoader.load(at: url)

    #expect(result.profiles == NewSessionLaunch.builtInDefaults)
    #expect(result.diagnostic?.contains("duplicate profile id") == true)
}

@Test func malformedOrEmptySessionLaunchProfilesFallBackToDefaults() {
    #expect(throws: Error.self) {
        try SessionLaunchProfileLoader.parse("session_launches:\n  - id: codex\n    label Codex")
    }
    #expect(throws: Error.self) {
        try SessionLaunchProfileLoader.parse("session_launches:\n")
    }

    let url = temporaryConfigURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! "session_launches:\n".write(to: url, atomically: true, encoding: .utf8)
    let result = SessionLaunchProfileLoader.load(at: url)
    #expect(result.profiles == NewSessionLaunch.builtInDefaults)
    #expect(result.diagnostic?.contains("must contain at least one profile") == true)
}

@Test func missingSessionLaunchConfigurationUsesBuiltInDefaultsWithoutDiagnostic() {
    let result = SessionLaunchProfileLoader.load(at: temporaryConfigURL())

    #expect(result.profiles == NewSessionLaunch.builtInDefaults)
    #expect(result.diagnostic == nil)
}

private func temporaryConfigURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("banyan-session-launch-tests-\(UUID().uuidString)")
        .appendingPathComponent("config.yml")
}
