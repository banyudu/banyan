import Foundation

/// Portable identity and resume-command rules for imported coding-agent history.
public enum AgentSessionHistory {
    public static func sourceID(fromImportedSessionID id: String, provider: CodingAgentProvider) -> String? {
        let prefix = "history-\(provider.rawValue)-"
        guard id.hasPrefix(prefix) else { return nil }
        let sourceID = String(id.dropFirst(prefix.count))
        return sourceID.isEmpty ? nil : sourceID
    }

    public static func resumeCommand(
        provider: CodingAgentProvider,
        sourceID: String,
        cwd: String,
        prompt: String? = nil
    ) -> String? {
        let cleanedPrompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        var arguments: [String]
        switch provider {
        case .codex:
            arguments = [
                provider.defaultExecutableName,
                "resume",
                "-C",
                cwd,
                sourceID
            ]
        case .claude:
            arguments = [
                provider.defaultExecutableName,
                "--resume",
                sourceID
            ]
        case .opencode, .deepseek, .hunyuan, .muse, .qwen:
            // All opencode-backed sessions share one SQLite store and resume via
            // the top-level `--session` flag. The stored session already carries
            // its agent/model, so a generic resume restores the conversation
            // without overriding it with launch-time flags. Previously this
            // returned nil, so Recover re-ran the launch command and every
            // opencode session came back as a blank new session.
            arguments = [
                "opencode",
                "--session",
                sourceID
            ]
        default:
            return nil
        }
        if let cleanedPrompt, !cleanedPrompt.isEmpty {
            arguments.append(cleanedPrompt)
        }
        return arguments.map(AgentLaunchCommand.shellQuote).joined(separator: " ")
    }
}
