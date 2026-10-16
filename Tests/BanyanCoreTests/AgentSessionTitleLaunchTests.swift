import Foundation
import Testing
@testable import BanyanCore

@Test func automaticTitleLaunchPreservesCodexProfileResumeAndPrompt() throws {
    let prompt = "what happened on https://example.com/events/42?\nUser's $(text) `literal`"
    let command = ["codex", "-p", "my-profile", "resume", "thread-1", prompt].map(AgentLaunchCommand.shellQuote).joined(separator: " ")
    let prepared = AgentSessionTitleLaunch.prepare(command: command, executable: "/tmp/My App/banyanctl",
        environment: ["BANYAN_SESSION_ID": "session-1", "BANYAN_FIXTURE_DATA_HOME": "/tmp/My Data"])
    let words = try #require(AgentSessionHistory.literalArguments(prepared.command, allowQuotedText: true))
    #expect(Array(words.suffix(5)) == ["-p", "my-profile", "resume", "thread-1", prompt])
    #expect(words.contains(#"mcp_servers.banyan_session.command="/tmp/My App/banyanctl""#))
    #expect(words.contains(#"mcp_servers.banyan_session.args=["__session-title-mcp","--id","session-1"]"#))
    #expect(words.contains(#"mcp_servers.banyan_session.env.BANYAN_FIXTURE_DATA_HOME="/tmp/My Data""#))
    #expect(prepared.environment.isEmpty)
}

@Test func automaticTitleLaunchMergesClaudeConfigWithoutReplacingExistingTools() throws {
    let original = ["claude", "--mcp-config", "/tmp/existing.json", "--model", "test-model", "Investigate checkout"].map(AgentLaunchCommand.shellQuote).joined(separator: " ")
    let prepared = AgentSessionTitleLaunch.prepare(command: original, executable: "/tmp/banyanctl", environment: ["BANYAN_SESSION_ID": "session-2"])
    let words = try #require(AgentDeepSuspend.launchArguments(prepared.command)?.words)
    let index = try #require(words.firstIndex(of: "--mcp-config"))
    let config = try #require(JSONSerialization.jsonObject(with: Data(words[index + 1].utf8)) as? [String: Any])
    let servers = try #require(config["mcpServers"] as? [String: [String: Any]])
    #expect(servers["banyan_session"]?["args"] as? [String] == ["__session-title-mcp", "--id", "session-2"])
    #expect(words[index + 2] == "/tmp/existing.json")
    #expect(Array(words.suffix(3)) == ["--model", "test-model", "Investigate checkout"])
}

@Test func automaticTitleLaunchMergesOpenCodeInlineConfig() throws {
    let prepared = AgentSessionTitleLaunch.prepare(command: "opencode --agent hy3", executable: "/tmp/banyanctl",
        environment: ["BANYAN_SESSION_ID": "session-3", "OPENCODE_CONFIG_CONTENT": #"{"model":"example/model","mcp":{"existing":{"type":"local","command":["example"]}}}"#])
    #expect(prepared.command == "opencode --agent hy3")
    let raw = try #require(prepared.environment["OPENCODE_CONFIG_CONTENT"])
    let config = try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    let servers = try #require(config["mcp"] as? [String: [String: Any]])
    #expect(config["model"] as? String == "example/model")
    #expect(servers["existing"]?["command"] as? [String] == ["example"])
    #expect(servers["banyan_session"]?["command"] as? [String] == ["/tmp/banyanctl", "__session-title-mcp", "--id", "session-3"])
}

@Test func automaticTitleLaunchRetainsCustomClaudeInstructionsAndInlineMCPConfig() throws {
    let command = ["claude", "--append-system-prompt", "Keep custom guidance", "--mcp-config=/tmp/existing.json", "Investigate checkout"]
        .map(AgentLaunchCommand.shellQuote).joined(separator: " ")
    let prepared = AgentSessionTitleLaunch.prepare(command: command, executable: "/tmp/banyanctl", environment: ["BANYAN_SESSION_ID": "session"])
    let words = try #require(AgentSessionHistory.literalArguments(prepared.command, allowQuotedText: true))
    let index = try #require(words.firstIndex(of: "--append-system-prompt"))
    #expect(words[index + 1].hasPrefix("Keep custom guidance\n\n"))
    #expect(words[index + 1].contains("rename_session"))
    #expect(words.contains("/tmp/existing.json"))
    #expect(words.last == "Investigate checkout")
}

@Test func automaticTitleLaunchDoesNotLetClaudeConsumeThePromptAsMCPConfig() throws {
    let prepared = AgentSessionTitleLaunch.prepare(command: "claude 'Investigate checkout'", executable: "/tmp/banyanctl", environment: ["BANYAN_SESSION_ID": "session"])
    let words = try #require(AgentSessionHistory.literalArguments(prepared.command, allowQuotedText: true))
    let prompt = try #require(words.firstIndex(of: "Investigate checkout"))
    let config = try #require(words.firstIndex(of: "--mcp-config"))
    #expect(prompt < config)
    #expect(config == words.count - 2)
}

@Test func automaticTitleLaunchLeavesUnsupportedAndDisabledInvocationsAlone() {
    for command in ["custom-wrapper codex", "codex && echo done", "echo 'codex'", "codex \"$PROMPT\"", "codex *.md", "codex; echo done", "codex\necho done", "codex --remote unix://"] {
        #expect(AgentSessionTitleLaunch.prepare(command: command, executable: "/tmp/banyanctl", environment: ["BANYAN_SESSION_ID": "session"]).command == command)
    }
    #expect(AgentSessionTitleLaunch.prepare(command: "codex", executable: "/tmp/banyanctl", environment: [:]).command == "codex")
    #expect(AgentSessionTitleLaunch.prepare(command: "codex", executable: "/tmp/banyanctl", environment: ["BANYAN_SESSION_ID": "session", "BANYAN_AUTO_RENAME": "0"]).command == "codex")
    let invalid = AgentSessionTitleLaunch.prepare(command: "opencode", executable: "/tmp/banyanctl", environment: ["BANYAN_SESSION_ID": "session", "OPENCODE_CONFIG_CONTENT": "{invalid}"])
    #expect(invalid.environment.isEmpty)
}

@Test func automaticTitleLaunchPreservesQuotedBackslashesAndLineContinuations() throws {
    let command = "codex \\\n --model example \"Investigate \\path\""
    let prepared = AgentSessionTitleLaunch.prepare(command: command, executable: "/tmp/banyanctl", environment: ["BANYAN_SESSION_ID": "session"])
    let words = try #require(AgentSessionHistory.literalArguments(prepared.command, allowQuotedText: true))
    #expect(Array(words.suffix(3)) == ["--model", "example", "Investigate \\path"])
    #expect(!words.contains(""))
}
