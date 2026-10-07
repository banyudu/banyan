import Foundation

/// Portable identity and resume-command rules for imported coding-agent history.
public enum AgentSessionHistory {
    /// Only literal argv can be safely wrapped or rewritten. Shell programs
    /// (including expansion inside double quotes) retain their original launch.
    public static func literalArguments(_ command: String) -> [String]? {
        guard let parsed = shellTokens(command), parsed.isLossless,
              !command.contains("$"), !command.contains("`"), !command.contains("\n") else { return nil }
        return parsed.tokens
    }

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

    /// The Codex config profile a launch command selected, e.g. `-p sol`.
    ///
    /// A profile is a separate config file (`~/.codex/<profile>.config.toml`)
    /// that defines the provider the conversation was recorded against. Codex
    /// replays that provider from the transcript on resume, so a resume that
    /// drops the profile fails outright with `Model provider '<name>' not found`
    /// — and the agent exits before the pane can even settle.
    public static func codexProfile(fromCommand command: String?) -> String? {
        guard let command, let parsed = shellTokens(command) else { return nil }
        let tokens = parsed.tokens
        guard let executable = tokens.firstIndex(where: { isCodexExecutable($0) }) else { return nil }

        var index = tokens.index(after: executable)
        while index < tokens.endIndex {
            let token = tokens[index]
            // A subcommand ends the launch options: a `-p` after it belongs to
            // that subcommand, not to the executable that read the profile.
            if Self.codexSubcommands.contains(token) { return nil }
            if let inline = profileValue(inlineFlag: token) { return inline.isEmpty ? nil : inline }
            if token == "-p" || token == "--profile" {
                let value = tokens.index(after: index)
                guard value < tokens.endIndex else { return nil }
                let profile = tokens[value]
                return profile.hasPrefix("-") ? nil : profile
            }
            index = tokens.index(after: index)
        }
        return nil
    }

    /// Rewrites a Codex resume command so it keeps the profile the conversation
    /// was created under. Anything that is not a plain `codex resume …`
    /// invocation — an app-server chain, a pipeline, a hand-written wrapper — is
    /// returned untouched, because re-quoting a command we did not build is how
    /// a recovery turns into a different command.
    public static func applyingCodexProfile(
        fromCommand previousCommand: String?,
        to resumeCommand: String
    ) -> String {
        guard let profile = codexProfile(fromCommand: previousCommand),
              let parsed = shellTokens(resumeCommand),
              // Re-quoting is only safe for a command with no shell syntax of
              // its own; anything richer was not built here and is not ours.
              parsed.isLossless,
              let executable = parsed.tokens.firstIndex(where: { isCodexExecutable($0) }) else {
            return resumeCommand
        }
        let tokens = parsed.tokens
        let subcommand = tokens.index(after: executable)
        guard subcommand < tokens.endIndex, tokens[subcommand] == "resume" else { return resumeCommand }
        guard !tokens.contains("-p"), !tokens.contains("--profile") else { return resumeCommand }
        guard !tokens.contains(where: { profileValue(inlineFlag: $0) != nil }) else { return resumeCommand }

        var rewritten = tokens
        rewritten.insert(contentsOf: ["-p", profile], at: subcommand)
        return rewritten.map(AgentLaunchCommand.shellQuote).joined(separator: " ")
    }

    private static let codexSubcommands: Set<String> = [
        "resume", "exec", "review", "login", "logout", "mcp", "apply", "completion", "help", "sandbox", "proto"
    ]

    private static func isCodexExecutable(_ token: String) -> Bool {
        (token as NSString).lastPathComponent == "codex"
    }

    /// `--profile=name` and `-p=name`, the two spellings that carry the value in
    /// the same token. A bare `--profile`/`-p` is handled by the caller.
    private static func profileValue(inlineFlag token: String) -> String? {
        for flag in ["--profile=", "-p="] where token.hasPrefix(flag) {
            return String(token.dropFirst(flag.count))
        }
        return nil
    }

    private struct TokenizedCommand {
        /// The words of the command, with shell operators treated as separators.
        var tokens: [String]
        /// False once the command shows shell syntax of its own — `&&`, a pipe, a
        /// substitution, a redirect. Reading a flag out of such a command is fine;
        /// re-quoting one is not, because the operators would be quoted away.
        var isLossless: Bool
    }

    /// Splits a command into words the way a POSIX shell would for the quoting
    /// Banyan itself writes, plus the single-quoted equivalent a human types.
    /// Returns `nil` only for input it cannot even read — an unterminated quote
    /// or a trailing backslash.
    private static func shellTokens(_ command: String) -> TokenizedCommand? {
        var tokens: [String] = []
        var current = ""
        var hasCurrent = false
        var isLossless = true
        var index = command.startIndex

        func finishCurrent() {
            guard hasCurrent else { return }
            tokens.append(current)
            current = ""
            hasCurrent = false
        }

        /// Skips a substitution or backtick run so its contents cannot be read as
        /// separate words (or mistaken for a flag).
        func skipBalanced(_ closing: Character, opens: Int) -> Bool {
            var depth = opens
            while index < command.endIndex {
                let character = command[index]
                if character == closing { depth -= 1 }
                if character == "(" && closing == ")" { depth += 1 }
                if character == "'" {
                    index = command.index(after: index)
                    while index < command.endIndex, command[index] != "'" {
                        index = command.index(after: index)
                    }
                    guard index < command.endIndex else { return false }
                }
                if depth == 0 {
                    index = command.index(after: index)
                    return true
                }
                index = command.index(after: index)
            }
            return false
        }

        while index < command.endIndex {
            let character = command[index]
            switch character {
            case "'", "\"":
                let quote = character
                hasCurrent = true
                index = command.index(after: index)
                while index < command.endIndex, command[index] != quote {
                    if quote == "\"", command[index] == "\\" {
                        let escaped = command.index(after: index)
                        guard escaped < command.endIndex else { return nil }
                        current.append(command[escaped])
                        index = command.index(after: escaped)
                        continue
                    }
                    current.append(command[index])
                    index = command.index(after: index)
                }
                guard index < command.endIndex else { return nil }
                index = command.index(after: index)
            case "\\":
                let escaped = command.index(after: index)
                guard escaped < command.endIndex else { return nil }
                current.append(command[escaped])
                hasCurrent = true
                index = command.index(after: escaped)
            case " ", "\t", "\n":
                finishCurrent()
                index = command.index(after: index)
            case "$":
                let next = command.index(after: index)
                guard next < command.endIndex, command[next] == "(" else { return nil }
                finishCurrent()
                isLossless = false
                index = command.index(after: next)
                guard skipBalanced(")", opens: 1) else { return nil }
            case "`":
                finishCurrent()
                isLossless = false
                index = command.index(after: index)
                guard skipBalanced("`", opens: 0) else { return nil }
            case "&", "|", ";", "<", ">", "(", ")", "{", "}":
                finishCurrent()
                isLossless = false
                index = command.index(after: index)
            default:
                current.append(character)
                hasCurrent = true
                index = command.index(after: index)
            }
        }
        finishCurrent()
        return TokenizedCommand(tokens: tokens, isLossless: isLossless)
    }
}
