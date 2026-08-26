@testable import Banyan
import Foundation
import Testing

private func tempHome() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("banyan-agents-fallback-\(UUID().uuidString)", isDirectory: true)
}

@Test func agentsFallbackWhenConfigOmitsSessionLaunches() throws {
    let home = tempHome()
    defer { try? FileManager.default.removeItem(at: home) }
    try FileManager.default.createDirectory(at: home.appendingPathComponent(".agents"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: home.appendingPathComponent(".banyan"), withIntermediateDirectories: true)

    // Minimal agents.yml with two banyan entries
    let agentsYAML = """
    agents:
      zsh:
        label: zsh
        tags: [banyan]
        command: ""
      codex:
        label: Codex
        provider: codex
        tags: [banyan]
        command: codex
        banyanCommand: codex
      ghost:
        label: Ghost
        command: ghost
    """
    try agentsYAML.write(to: home.appendingPathComponent(".agents/agents.yml"), atomically: true, encoding: .utf8)

    // Config without session_launches — should trigger agents fallback, not error
    let configWithoutLaunches = """
    telemetry:
      enabled: false
    """
    try configWithoutLaunches.write(to: home.appendingPathComponent(".banyan/config.yml"), atomically: true, encoding: .utf8)

    let result = SessionLaunchProfileLoader.load(homeDirectory: home)
    #expect(result.profiles.map(\.id) == ["zsh", "codex", "claude"])
    // zsh/codex from agents, claude merged from builtInDefaults (since agents lacks it)
    #expect(result.diagnostic == nil)
    #expect(result.profiles.first { $0.id == "zsh" }?.command == "")
    #expect(result.profiles.first { $0.id == "codex" }?.command == "codex")
    // ghost (no banyan tag) should not appear
    #expect(result.profiles.first { $0.id == "ghost" } == nil)
}

@Test func agentsFallbackBanyanCommandPreferred() throws {
    let yaml = """
    agents:
      claude:
        label: Opus
        provider: opus
        tags: [banyan]
        command: claude --dangerously-skip-permissions --model 'opus' --effort xhigh
        banyanCommand: claude
    """
    let profiles = try SessionLaunchProfileLoader.parseAgents(yaml)
    #expect(profiles.count == 1)
    #expect(profiles[0].id == "claude")
    #expect(profiles[0].command == "claude")
    #expect(profiles[0].label == "Opus")
    #expect(profiles[0].providerName == "opus")
}

@Test func agentsFallbackFiltersByTagAndPicker() throws {
    let yaml = """
    agents:
      a:
        tags: [banyan]
        command: echo a
      b:
        tags: [coding]
        command: echo b
      c:
        tags: [banyan]
        picker: false
        command: echo c
      d:
        tags: [banyan]
        # no command — should be skipped
      zsh:
        tags: [banyan]
        command: ""
    """
    let profiles = try SessionLaunchProfileLoader.parseAgents(yaml)
    #expect(profiles.map(\.id) == ["a", "zsh"])
}

@Test func configWithSessionLaunchesTakesPrecedenceOverAgents() throws {
    let home = tempHome()
    defer { try? FileManager.default.removeItem(at: home) }
    try FileManager.default.createDirectory(at: home.appendingPathComponent(".agents"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: home.appendingPathComponent(".banyan"), withIntermediateDirectories: true)

    let agentsYAML = """
    agents:
      from-agents:
        tags: [banyan]
        command: echo agents
    """
    try agentsYAML.write(to: home.appendingPathComponent(".agents/agents.yml"), atomically: true, encoding: .utf8)

    let configYAML = """
    session_launches:
      - id: from-config
        label: From Config
        command: echo config
    """
    try configYAML.write(to: home.appendingPathComponent(".banyan/config.yml"), atomically: true, encoding: .utf8)

    let result = SessionLaunchProfileLoader.load(homeDirectory: home)
    #expect(result.profiles.contains { $0.id == "from-config" })
    #expect(!result.profiles.contains { $0.id == "from-agents" })
    // builtins merged
    #expect(result.profiles.contains { $0.id == "claude" })
}

@Test func missingAgentsFallsBackToBuiltins() throws {
    let home = tempHome()
    defer { try? FileManager.default.removeItem(at: home) }
    try FileManager.default.createDirectory(at: home.appendingPathComponent(".banyan"), withIntermediateDirectories: true)
    // no agents file, no config session_launches -> just telemetry
    let config = "telemetry:\n  enabled: false\n"
    try config.write(to: home.appendingPathComponent(".banyan/config.yml"), atomically: true, encoding: .utf8)

    let result = SessionLaunchProfileLoader.load(homeDirectory: home)
    #expect(result.profiles == NewSessionLaunch.builtInDefaults)
    #expect(result.diagnostic == nil)
}

@Test func realAgentsFileParsesToSameAsConfig() throws {
    // Use the real home's agents.yml if present
    let home = URL(fileURLWithPath: NSHomeDirectory())
    guard FileManager.default.fileExists(atPath: SessionLaunchProfileLoader.agentsURL(homeDirectory: home).path) else { return }
    let agentsContents = try String(contentsOf: SessionLaunchProfileLoader.agentsURL(homeDirectory: home), encoding: .utf8)
    let agentsProfiles = try SessionLaunchProfileLoader.parseAgents(agentsContents)
    // Should contain the 13 expected ids
    let ids = Set(agentsProfiles.map(\.id))
    #expect(ids.contains("zsh"))
    #expect(ids.contains("claude"))
    #expect(ids.contains("codex"))
    #expect(ids.contains("dpsk-flash"))
    #expect(ids.contains("oxalpha"))
    // Picker false entries must not appear
    #expect(!ids.contains("office-dgx-spark"))
    #expect(!ids.contains("build"))
}
