import Foundation

public struct AgentResumePlan: Equatable, Sendable {
    public let provider: CodingAgentProvider
    public let sourceID: String
    public let command: String

    public init(provider: CodingAgentProvider, sourceID: String, command: String) {
        self.provider = provider
        self.sourceID = sourceID
        self.command = command
    }
}

public enum AgentResumeCommand {
    public static func plan(
        provider: CodingAgentProvider,
        sourceID: String,
        cwd: String,
        launchCommand: String,
        baseResumeCommand: String? = nil
    ) throws -> AgentResumePlan {
        guard let base = baseResumeCommand ?? AgentSessionHistory.resumeCommand(
            provider: provider,
            sourceID: sourceID,
            cwd: cwd
        ) else {
            throw AgentFreezeError.unsafe("No provider resume command could be constructed; the original command was not restarted.")
        }
        guard let launchWords = AgentSessionHistory.providerLaunchWords(
            in: launchCommand,
            provider: provider,
            cwd: cwd
        ) else {
            throw AgentFreezeError.unsafe("The launch command has an unsupported wrapper or shell syntax; the original command was not restarted.")
        }
        let executableName = provider.isOpencodeBacked ? "opencode" : provider.defaultExecutableName
        guard let executableIndex = launchWords.firstIndex(where: {
            ($0 as NSString).lastPathComponent == executableName
        }) else {
            throw AgentFreezeError.unsafe("The launch command does not contain the expected provider executable.")
        }
        let executable = launchWords[executableIndex]
        guard !containsShellExpansion(executable) else {
            throw AgentFreezeError.unsafe("The provider executable uses shell expansion; the original command was not restarted.")
        }
        guard !isEnvironmentAssignment(executable) else {
            throw AgentFreezeError.unsafe("The launch command does not contain the expected provider executable.")
        }
        let environment = renderedEnvironment(Array(launchWords[..<executableIndex]))
        let arguments = Array(launchWords.dropFirst(executableIndex + 1))

        guard let baseWords = AgentSessionHistory.literalArguments(base, allowQuotedText: true),
              let baseExecutableIndex = baseWords.firstIndex(where: {
                  ($0 as NSString).lastPathComponent == executableName
              }), baseExecutableIndex + 1 < baseWords.count else {
            throw AgentFreezeError.unsafe("The provider resume command is not a literal invocation; nothing was restarted.")
        }
        let resumeTail = Array(baseWords.dropFirst(baseExecutableIndex + 1))
        guard resumeTail.contains(sourceID) else {
            throw AgentFreezeError.unsafe("The provider resume command does not contain the expected conversation ID; nothing was restarted.")
        }
        let options = try preservedOptions(
            provider: provider.isOpencodeBacked ? .opencode : provider,
            arguments: arguments
        )
        let command = (environment + [AgentLaunchCommand.shellQuote(executable)]
            + (options + resumeTail).map(AgentLaunchCommand.shellQuote))
            .joined(separator: " ")
        return AgentResumePlan(provider: provider, sourceID: sourceID, command: command)
    }

    public static func samePaneCommand(_ plan: AgentResumePlan, host: String, shell: String) -> String {
        [host, AgentProcessHost.subcommand, AgentProcessHost.inheritedFlag, shell, plan.command]
            .map(AgentLaunchCommand.shellQuote)
            .joined(separator: " ")
    }

    private static func renderedEnvironment(_ words: [String]) -> [String] {
        var words = words
        if words.first == "exec" { words.removeFirst() }
        if words.first == "env" {
            words.removeFirst()
            return [AgentLaunchCommand.shellQuote("env")] + words.map(AgentLaunchCommand.shellQuote)
        }
        return words.map { assignment in
            guard let equals = assignment.firstIndex(of: "=") else { return AgentLaunchCommand.shellQuote(assignment) }
            let key = assignment[..<equals]
            let value = assignment[assignment.index(after: equals)...]
            return "\(key)=\(AgentLaunchCommand.shellQuote(String(value)))"
        }
    }

    private static func preservedOptions(
        provider: CodingAgentProvider,
        arguments: [String]
    ) throws -> [String] {
        let takesValue: Set<String>
        let switches: Set<String>
        let identityFlags: Set<String>
        let variadicOptions: Set<String>
        switch provider {
        case .codex:
            takesValue = ["-p", "--profile", "-c", "--config", "-m", "--model", "-s", "--sandbox", "-a", "--ask-for-approval",
                "--add-dir", "--enable", "--disable"]
            switches = ["--no-daemon", "--dangerously-bypass-approvals-and-sandbox", "--full-auto", "--no-alt-screen", "--search"]
            identityFlags = ["-C", "--cd"]
            variadicOptions = ["--add-dir"]
        case .claude:
            takesValue = ["--model", "--permission-mode", "--effort", "--settings", "--mcp-config", "--add-dir",
                "--append-system-prompt", "--system-prompt", "--allowedTools", "--disallowedTools", "--tools", "--plugin-dir"]
            switches = ["--dangerously-skip-permissions", "--allow-dangerously-skip-permissions", "--strict-mcp-config"]
            identityFlags = ["--resume", "-r", "--session-id"]
            variadicOptions = ["--allowedTools", "--disallowedTools", "--tools", "--add-dir", "--plugin-dir"]
        case .opencode:
            takesValue = ["-m", "--model", "--agent"]
            switches = ["--pure", "--auto", "--mini"]
            identityFlags = ["--session", "-s"]
            variadicOptions = []
        default:
            throw AgentFreezeError.unsafe("Provider has no safe resume option schema")
        }

        var options: [String] = []
        var index = 0
        while index < arguments.count {
            let word = arguments[index]
            if provider == .codex, word == "resume" { index += 1; continue }
            if identityFlags.contains(word) {
                if provider == .claude, ["--resume", "-r"].contains(word) {
                    index += index + 1 < arguments.count && !arguments[index + 1].hasPrefix("-") ? 2 : 1
                } else {
                    guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("-") else {
                        throw AgentFreezeError.unsafe("Missing provider identity/cwd option value")
                    }
                    index += 2
                }
                continue
            }
            if AgentDeepSuspend.validID(word, provider: provider) { index += 1; continue }
            if takesValue.contains(word) {
                guard index + 1 < arguments.count else { throw AgentFreezeError.unsafe("Missing launch option value") }
                guard !containsShellExpansion(word), !containsShellExpansion(arguments[index + 1]) else {
                    throw AgentFreezeError.unsafe("A launch option uses shell expansion; the original command was not restarted.")
                }
                if variadicOptions.contains(word), index + 2 < arguments.count, !arguments[index + 2].hasPrefix("-") {
                    throw AgentFreezeError.unsafe("Ambiguous variadic permission/launch option; use an inline value before restarting")
                }
                options += [word, arguments[index + 1]]
                index += 2
                continue
            }
            if switches.contains(word) {
                guard !containsShellExpansion(word) else {
                    throw AgentFreezeError.unsafe("A launch option uses shell expansion; the original command was not restarted.")
                }
                options.append(word)
                index += 1
                continue
            }
            if word.hasPrefix("-"), let flag = word.split(separator: "=", maxSplits: 1).first,
               takesValue.contains(String(flag)) || identityFlags.contains(String(flag)) {
                if takesValue.contains(String(flag)) {
                    guard !containsShellExpansion(word) else {
                        throw AgentFreezeError.unsafe("A launch option uses shell expansion; the original command was not restarted.")
                    }
                    options.append(word)
                }
                index += 1
                continue
            }
            guard index == arguments.count - 1, !word.hasPrefix("-"),
                  !["exec", "run", "attach", "serve", "web", "app-server", "--fork"].contains(word) else {
                throw AgentFreezeError.unsafe("Launch options cannot be safely preserved on resume")
            }
            index += 1
        }
        return options
    }

    private static func containsShellExpansion(_ word: String) -> Bool {
        word.rangeOfCharacter(from: shellExpansionCharacters) != nil || word.hasPrefix("#")
    }

    private static func isEnvironmentAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        let key = word[..<equals]
        return (key.first == "_" || key.first?.isLetter == true)
            && key.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }

    private static let shellExpansionCharacters = CharacterSet(charactersIn: "$`*?[]~")
}
