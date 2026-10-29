import Foundation

/// Portable identity and resume-command rules for imported coding-agent history.
public enum AgentSessionHistory {
    /// Only literal argv can be safely wrapped or rewritten. Shell programs
    /// (including expansion inside double quotes) retain their original launch.
    public static func literalArguments(_ command: String) -> [String]? {
        literalArguments(command, allowQuotedText: false)
    }

    public static func literalArguments(_ command: String, allowQuotedText: Bool) -> [String]? {
        guard let parsed = shellTokens(command, forLiteralLaunch: allowQuotedText), parsed.isLossless else { return nil }
        // Recovery keeps its existing conservative contract. Invocation-only
        // metadata may also handle safely quoted, multiline user prompts.
        guard allowQuotedText || (!command.contains("$") && !command.contains("`") && !command.contains("\n")) else { return nil }
        return parsed.tokens
    }

    /// The provider invocation from a literal launch or the one supported shell
    /// wrapper (`cd <session-cwd> && ...`). Environment assignments and `exec`
    /// prefixes are retained so callers can rebuild the command without replaying
    /// the original prompt.
    public static func providerLaunchWords(
        in command: String,
        provider: CodingAgentProvider,
        cwd: String
    ) -> [String]? {
        guard let parsed = shellTokens(command, forLiteralLaunch: true) else { return nil }
        guard !parsed.hasUnquotedExpansion else { return nil }
        let providerSegments = parsed.segments.indices.filter { index in
            parsed.segments[index].contains { token in
                (token as NSString).lastPathComponent == provider.resumeExecutableName
            }
        }
        guard providerSegments.count == 1, let providerIndex = providerSegments.first,
              providerIndex == parsed.segments.count - 1 else { return nil }
        if providerIndex == 1 {
            guard let separator = parsed.separators.first, ["&&", ";", "\n"].contains(separator),
                  isSessionCWDChange(parsed.segments[0], cwd: cwd) else { return nil }
        } else if providerIndex != 0 {
            return nil
        }

        let segment = parsed.segments[providerIndex]
        guard let executableIndex = segment.firstIndex(where: {
            ($0 as NSString).lastPathComponent == provider.resumeExecutableName
        }), !segment.dropFirst(executableIndex + 1).contains(where: {
            ($0 as NSString).lastPathComponent == provider.resumeExecutableName
        }) else { return nil }

        var prefix = Array(segment[..<executableIndex])
        if prefix.first == "exec" { prefix.removeFirst() }
        if prefix.first == "env" {
            prefix.removeFirst()
            guard !prefix.isEmpty, prefix.allSatisfy(isLiteralEnvironmentAssignment) else { return nil }
        } else {
            guard prefix.allSatisfy(isLiteralEnvironmentAssignment) else { return nil }
        }
        return segment
    }

    /// Extract only unambiguous literal resume invocations. Shell pipelines and
    /// unknown options are left unbound rather than guessing at their meaning.
    public static func explicitResumeIdentity(in command: String) -> (provider: CodingAgentProvider, sourceID: String)? {
        // Banyan's app-server launch has a fixed daemon prelude. Parse only
        // its literal TUI invocation, never an arbitrary shell command.
        let appServerPrefix = "'codex' 'remote-control' 'start' && exec "
        let invocation = command.hasPrefix(appServerPrefix) ? String(command.dropFirst(appServerPrefix.count)) : command
        guard let args = literalArguments(invocation), let executable = args.first else { return nil }
        let name = (executable as NSString).lastPathComponent
        if name == "claude" || name == "opencode" {
            let flags = name == "claude" ? ["--resume", "-r"] : ["--session", "-s"]
            // Only bind the leading resume flag. A later flag-like word could
            // be a prompt or another option's value.
            guard args.count >= 3, flags.contains(args[1]),
                  !args[2].isEmpty, !args[2].hasPrefix("-") else { return nil }
            return (name == "claude" ? .claude : .opencode, args[2])
        }
        guard name == "codex" else { return nil }
        var index = 1
        let valueOptions: Set<String> = ["-C", "--cd", "-p", "--profile", "-m", "--model", "-c", "--config", "-s", "--sandbox", "-a", "--ask-for-approval", "--remote"]
        let switchOptions: Set<String> = ["--no-daemon", "--full-auto", "--dangerously-bypass-approvals-and-sandbox", "--search", "--oss", "--all"]
        var sawResume = false
        while index < args.count {
            let arg = args[index]
            if !sawResume && arg == "resume" { sawResume = true; index += 1; continue }
            if valueOptions.contains(arg) { index += 2; continue }
            if switchOptions.contains(arg) { index += 1; continue }
            if arg.hasPrefix("-") { return nil }
            guard sawResume, !arg.isEmpty else { return nil }
            return (.codex, arg)
        }
        return nil
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

    private static func isSessionCWDChange(_ words: [String], cwd: String) -> Bool {
        guard words.count == 2, words[0] == "cd", !words[1].contains("$"), !words[1].contains("`") else { return false }
        let target = words[1].hasPrefix("/")
            ? URL(fileURLWithPath: words[1])
            : URL(fileURLWithPath: cwd).appendingPathComponent(words[1])
        return PathDisplayName.canonicalPath(target.standardizedFileURL.path) == PathDisplayName.canonicalPath(cwd)
    }

    private static func isLiteralEnvironmentAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        let key = word[..<equals]
        guard key.first == "_" || key.first?.isLetter == true,
              key.allSatisfy({ $0 == "_" || $0.isLetter || $0.isNumber }) else { return false }
        let value = word[word.index(after: equals)...]
        return value.rangeOfCharacter(from: shellExpansionCharacters) == nil
    }

    private static let shellExpansionCharacters = CharacterSet(charactersIn: "$`*?[]~")

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
        var segments: [[String]]
        var separators: [String]
        var hasUnquotedExpansion: Bool
        /// False once the command shows shell syntax of its own — `&&`, a pipe, a
        /// substitution, a redirect. Reading a flag out of such a command is fine;
        /// re-quoting one is not, because the operators would be quoted away.
        var isLossless: Bool
    }

    /// Splits a command into words the way a POSIX shell would for the quoting
    /// Banyan itself writes, plus the single-quoted equivalent a human types.
    /// Returns `nil` only for input it cannot even read — an unterminated quote
    /// or a trailing backslash.
    private static func shellTokens(_ command: String, forLiteralLaunch: Bool = false) -> TokenizedCommand? {
        var tokens: [String] = []
        var segments: [[String]] = [[]]
        var separators: [String] = []
        var hasUnquotedExpansion = false
        var current = ""
        var hasCurrent = false
        var isLossless = true
        var index = command.startIndex

        func finishCurrent() {
            guard hasCurrent else { return }
            tokens.append(current)
            segments[segments.count - 1].append(current)
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
                        if forLiteralLaunch, !"$`\"\\\n".contains(command[escaped]) { current.append("\\") }
                        if !forLiteralLaunch || command[escaped] != "\n" { current.append(command[escaped]) }
                        index = command.index(after: escaped)
                        continue
                    }
                    if forLiteralLaunch, quote == "\"", "$`".contains(command[index]) { isLossless = false }
                    current.append(command[index])
                    index = command.index(after: index)
                }
                guard index < command.endIndex else { return nil }
                index = command.index(after: index)
            case "\\":
                let escaped = command.index(after: index)
                guard escaped < command.endIndex else { return nil }
                if !forLiteralLaunch || command[escaped] != "\n" {
                    current.append(command[escaped])
                    hasCurrent = true
                }
                index = command.index(after: escaped)
            case " ", "\t":
                finishCurrent()
                index = command.index(after: index)
            case "\n":
                if forLiteralLaunch { isLossless = false }
                finishCurrent()
                separators.append("\n")
                segments.append([])
                index = command.index(after: index)
            case "$":
                let next = command.index(after: index)
                guard next < command.endIndex, command[next] == "(" else { return nil }
                finishCurrent()
                isLossless = false
                hasUnquotedExpansion = true
                index = command.index(after: next)
                guard skipBalanced(")", opens: 1) else { return nil }
            case "`":
                finishCurrent()
                isLossless = false
                hasUnquotedExpansion = true
                index = command.index(after: index)
                guard skipBalanced("`", opens: 0) else { return nil }
            case "&", "|", ";", "<", ">", "(", ")", "{", "}":
                finishCurrent()
                isLossless = false
                index = command.index(after: index)
                var separator = String(character)
                if ["&", "|", ">"].contains(character), index < command.endIndex, command[index] == character {
                    separator.append(command[index])
                    index = command.index(after: index)
                }
                separators.append(separator)
                segments.append([])
            default:
                if forLiteralLaunch, "*?[]~#".contains(character) { isLossless = false }
                current.append(character)
                hasCurrent = true
                index = command.index(after: index)
            }
        }
        finishCurrent()
        return TokenizedCommand(tokens: tokens, segments: segments, separators: separators,
            hasUnquotedExpansion: hasUnquotedExpansion, isLossless: isLossless)
    }
}

private extension CodingAgentProvider {
    var resumeExecutableName: String {
        isOpencodeBacked ? "opencode" : defaultExecutableName
    }
}
