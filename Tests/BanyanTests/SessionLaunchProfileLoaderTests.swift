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
    #expect(profiles[1].command == "claude --model opus --dangerously-skip-permissions")
    #expect(profiles[1].iconName == "~/.banyan/icons/claude-opus.png")
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
