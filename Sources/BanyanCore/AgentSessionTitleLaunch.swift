import Foundation

/// Adds a private rename tool for this invocation without editing agent configs
/// or replacing their existing system/developer instructions.
public enum AgentSessionTitleLaunch {
    public struct Prepared {
        public let command: String
        public var environment: [String: String] = [:]
    }

    public static func isEnabled(environment: [String: String]) -> Bool {
        !["0", "false", "off"].contains(environment["BANYAN_AUTO_RENAME"]?.lowercased() ?? "")
    }

    public static func codexServerConfiguration(sessionID: String, executable: String, environment: [String: String]) -> [String: Any] {
        ["command": executable, "args": [SessionTitleMCP.subcommand, "--id", sessionID],
         "env": forwardedEnvironment(environment), "enabled_tools": [SessionTitleMCP.toolName]]
    }

    public static func prepare(command: String, executable: String, environment: [String: String]) -> Prepared {
        let unchanged = Prepared(command: command)
        guard isEnabled(environment: environment),
              let sessionID = environment[BanyanSessionEnvironment.sessionIDKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty,
              let invocation = literalInvocation(command),
              let first = invocation.words.first else { return unchanged }
        let provider = (first as NSString).lastPathComponent
        let quote = AgentLaunchCommand.shellQuote
        var words = invocation.words
        switch provider {
        case "codex":
            guard !words.contains(where: { $0 == "--remote" || $0.hasPrefix("--remote=") }) else { return unchanged }
            // Global options precede resume/fork subcommands and positional prompts.
            let config = codexServerConfiguration(sessionID: sessionID, executable: executable, environment: environment)
            var options: [String] = []
            for key in config.keys.sorted() {
                guard let entry = config[key],
                      let value = try? JSONSerialization.data(withJSONObject: entry, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]),
                      let json = String(data: value, encoding: .utf8) else { return unchanged }
                // JSON strings/arrays also use valid TOML basic-string syntax.
                // `env` is expanded into individual keys instead of a JSON table.
                if key == "env", let env = config[key] as? [String: String] {
                    for name in env.keys.sorted() {
                        guard let value = env[name],
                              let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]) else { return unchanged }
                        options += ["-c", "mcp_servers.\(SessionTitleMCP.serverName).env.\(name)=\(String(decoding: data, as: UTF8.self))"]
                    }
                } else {
                    options += ["-c", "mcp_servers.\(SessionTitleMCP.serverName).\(key)=\(json)"]
                }
            }
            words.insert(contentsOf: options, at: 1)
        case "claude":
            let config: [String: Any] = ["mcpServers": [SessionTitleMCP.serverName: [
                "type": "stdio", "command": executable, "args": [SessionTitleMCP.subcommand, "--id", sessionID],
                "env": forwardedEnvironment(environment)
            ]]]
            guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]) else { return unchanged }
            let json = String(decoding: data, as: UTF8.self)
            if let index = words.firstIndex(of: "--mcp-config") {
                words.insert(json, at: index + 1)
            } else if let index = words.firstIndex(where: { $0.hasPrefix("--mcp-config=") }) {
                let existing = String(words.remove(at: index).dropFirst("--mcp-config=".count))
                words.insert(contentsOf: ["--mcp-config", json, existing], at: index)
            } else {
                // This option is variadic. Placing it before a positional
                // prompt would make Claude consume the prompt as another config.
                words.append(contentsOf: ["--mcp-config", json])
            }
            // Claude can defer MCP tool descriptions until searched. Make the
            // naming workflow discoverable while retaining a custom append.
            if let index = words.lastIndex(of: "--append-system-prompt"), index + 1 < words.count {
                words[index + 1] += "\n\n" + SessionTitleMCP.instructions
            } else if let index = words.lastIndex(where: { $0.hasPrefix("--append-system-prompt=") }) {
                words[index] += "\n\n" + SessionTitleMCP.instructions
            } else if !words.contains(where: { $0 == "--append-system-prompt-file" || $0.hasPrefix("--append-system-prompt-file=") }) {
                words.insert(contentsOf: ["--append-system-prompt", SessionTitleMCP.instructions], at: 1)
            }
        case "opencode":
            // Inline config is a final, merged layer. Keep any user-supplied
            // options and other servers, and decline to rewrite non-JSON config.
            var config: [String: Any] = [:]
            if let existing = environment["OPENCODE_CONFIG_CONTENT"] {
                guard let parsed = try? JSONSerialization.jsonObject(with: Data(existing.utf8)) as? [String: Any] else { return unchanged }
                config = parsed
            }
            var servers = config["mcp"] as? [String: Any] ?? [:]
            guard servers[SessionTitleMCP.serverName] == nil else { return unchanged }
            servers[SessionTitleMCP.serverName] = ["type": "local", "command": [executable, SessionTitleMCP.subcommand, "--id", sessionID],
                                                 "environment": forwardedEnvironment(environment), "enabled": true]
            config["mcp"] = servers
            guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]) else { return unchanged }
            return Prepared(command: command, environment: ["OPENCODE_CONFIG_CONTENT": String(decoding: data, as: UTF8.self)])
        default: return unchanged
        }
        return Prepared(command: (invocation.environment + words).map(quote).joined(separator: " "))
    }

    private static func forwardedEnvironment(_ environment: [String: String]) -> [String: String] {
        // Some agent daemons filter inherited environment. Forward only the
        // location overrides needed for the same local control server/data root.
        environment.filter { ["BANYAN_FIXTURE_CONTROL_URL", "BANYAN_FIXTURE_DATA_HOME", "XDG_DATA_HOME"].contains($0.key) }
    }

    private static func literalInvocation(_ command: String) -> (words: [String], environment: [String])? {
        guard var words = AgentSessionHistory.literalArguments(command, allowQuotedText: true), !words.isEmpty else { return nil }
        if words.first == "exec" { words.removeFirst() }
        var environment: [String] = []
        if words.first == "env" {
            words.removeFirst()
            guard words.first == "OPENCODE_DISABLE_AUTOUPDATE=true" else { return nil }
            environment = ["env", words.removeFirst()]
        }
        return (words, environment)
    }
}
