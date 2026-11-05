import BanyanCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension BanyanCtl {
    func parsePayload(_ args: [String]) throws -> [String: String] {
        var result: [String: String] = [:]
        var index = 0
        while index < args.count {
            let token = args[index]
            guard token.hasPrefix("--") else {
                throw CLIError.message("unexpected argument '\(token)'")
            }
            let rawKey = String(token.dropFirst(2))
            if let flag = Self.booleanFocusFlag(for: rawKey) {
                result["focus"] = flag
                index += 1
                continue
            }
            if rawKey == "no-parent" {
                // Explicit top-level: the empty value blocks the env/tmux
                // default in withDefaultParent, and the server treats empty
                // the same as absent.
                result["parent"] = ""
                index += 1
                continue
            }
            let key: String
            switch rawKey {
            case "cmd":
                key = "command"
            case "parent-id", "parentSessionID":
                key = "parent"
            case "title-url", "titleURL":
                key = "titleURL"
            default:
                key = rawKey
            }
            guard index + 1 < args.count else {
                throw CLIError.message("missing value for \(token)")
            }
            result[key] = args[index + 1]
            index += 2
        }
        return result
    }

    /// Fills in `--parent` when the caller did not give one explicitly, so a
    /// session spawned from inside another session nests under it by default.
    /// An explicit `--parent` (even empty) or `--no-parent` disables the
    /// default; pass one of those for a top-level session.
    func withDefaultParent(_ payload: [String: String]) -> [String: String] {
        var payload = payload
        guard payload["parent"] == nil, let parent = defaultParentSessionID() else {
            return payload
        }
        payload["parent"] = parent
        return payload
    }

    /// Parent for a spawn issued from inside a Banyan session: explicit env
    /// first, otherwise the enclosing tmux session when running inside one.
    /// The live tmux name outranks `BANYAN_SESSION_ID`, which can be stale in
    /// long-lived daemons that inherited it from a pane that has since closed.
    private func defaultParentSessionID() -> String? {
        BanyanSessionEnvironment.parentSessionID(
            from: host.environment,
            enclosingTmuxSessionID: enclosingTmuxSessionID(environment: host.environment)
        )
    }

    func currentSessionID() -> String? {
        let environment = host.environment
        if environment["TMUX"] == nil, environment["TMUX_PANE"] == nil,
           let thread = environment["CODEX_THREAD_ID"], !thread.isEmpty {
            guard let catalog = try? loadShellSessions(options: SessionListOptions(queryItems: ["query": thread])) else { return nil }
            let matches = catalog.sessions.filter { $0["backend"] as? String == "codex" && $0["agentSessionID"] as? String == thread }
            return matches.count == 1 ? matches[0]["id"] as? String : nil
        }
        return BanyanSessionEnvironment.currentSessionID(from: environment,
            enclosingTmuxSessionID: enclosingTmuxSessionID(environment: environment))
    }

    /// Banyan id of the tmux session this process runs inside, if any.
    /// Covers shells in sessions created before `BANYAN_SESSION_ID` injection
    /// existed, and any spawner that does not forward the variable. Sessions
    /// on a foreign tmux server (no `banyan-` prefix) yield nil.
    func enclosingTmuxSessionID(environment: [String: String]) -> String? {
        guard environment["TMUX_PANE"] != nil || environment["TMUX"] != nil else {
            return nil
        }
        let target = environment["TMUX_PANE"].map { ["-t", $0] } ?? []
        let tmuxArguments: [String]
        if let socket = environment["TMUX"]?.split(separator: ",").first.map(String.init),
           !socket.isEmpty {
            tmuxArguments = ["tmux", "-S", socket, "display-message", "-p"] + target + ["#{session_name}"]
        } else {
            tmuxArguments = ["tmux", "-L", TmuxBackend.socketName, "display-message", "-p"] + target + ["#{session_name}"]
        }
        // `tmux` resolves through the caller's PATH; tmux looks at TMUX/TMUX_PANE
        // in the child's environment to pick the client, so forward everything.
        var queryEnvironment = environment
        let currentPath = queryEnvironment["PATH"] ?? ""
        let merged = (HostExecutablePaths.systemPaths() + currentPath.split(separator: ":").map(String.init))
            .reduce(into: [String]()) { paths, path in
                if !paths.contains(path) {
                    paths.append(path)
                }
            }
            .joined(separator: ":")
        queryEnvironment["PATH"] = merged
        guard let output = try? SubprocessRunner.run(
            arguments: tmuxArguments,
            cwd: host.homeDirectory.path,
            environment: queryEnvironment,
            timeout: 2
        ), output.terminationStatus == 0 else {
            return nil
        }
        let name = String(decoding: output.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return BanyanSessionEnvironment.sessionID(fromTmuxSessionName: name)
    }

    /// `prune` drives the running app rather than the database file: the app
    /// rewrites the whole `sessions` table on its next supervisor tick, so rows
    /// deleted behind its back would simply come back.
    func parsePrunePayload(_ args: [String]) throws -> [String: String] {
        var payload: [String: String] = [:]
        var index = 0
        while index < args.count {
            let token = args[index]
            switch token {
            case "--dry-run":
                payload["dryRun"] = "true"
                index += 1
            case "--older-than":
                guard index + 1 < args.count else {
                    throw CLIError.message("missing value for \(token)")
                }
                guard let days = SessionRetentionPolicy.retentionDays(fromDurationArgument: args[index + 1]) else {
                    throw CLIError.message("\(token) must be a non-negative number of days, like 30 or 30d")
                }
                payload["days"] = String(days)
                index += 2
            default:
                throw CLIError.message("unknown prune option '\(token)'")
            }
        }
        return payload
    }

    func parseOutputOptions(_ args: [String]) throws -> [String: String] {
        var query = try parsePayload(args)
        query.removeValue(forKey: "json")
        guard query["id"]?.isEmpty == false else {
            throw CLIError.message("output requires --id ID")
        }
        return query
    }

    func parseEventsOptions(_ args: [String]) throws -> [String: String] {
        try parsePayload(args)
    }

    /// `send` is the raw path: named keys stay a list so `--key Down --key Enter`
    /// keeps its order, and `--text` is never read as a key name.
    func parseSendPayload(_ args: [String]) throws -> [String: Any] {
        var payload: [String: Any] = [:]
        var keys: [String] = []
        var index = 0
        while index < args.count {
            let token = args[index]
            guard token.hasPrefix("--") else {
                throw CLIError.message("unexpected argument '\(token)'")
            }
            let key = String(token.dropFirst(2))
            if key == "submit" {
                payload["submit"] = true
                index += 1
                continue
            }
            guard index + 1 < args.count else {
                throw CLIError.message("missing value for \(token)")
            }
            let value = args[index + 1]
            switch key {
            case "key", "keys":
                keys.append(value)
            case "id", "text":
                payload[key] = value
            default:
                throw CLIError.message("unknown send option '\(token)'")
            }
            index += 2
        }
        guard payload["id"] != nil else {
            throw CLIError.message("send requires --id ID")
        }
        if !keys.isEmpty {
            payload["keys"] = keys
        }
        guard payload["keys"] != nil || payload["text"] != nil || payload["submit"] != nil else {
            throw CLIError.message("send requires --key NAME, --text TEXT or --submit")
        }
        return payload
    }

    func parseAnswerPayload(_ args: [String]) throws -> [String: Any] {
        var payload: [String: Any] = [:]
        var index = 0
        while index < args.count {
            let token = args[index]
            guard token.hasPrefix("--") else {
                throw CLIError.message("unexpected argument '\(token)'")
            }
            let key = String(token.dropFirst(2))
            if key == "confirm" {
                payload["confirm"] = true
                index += 1
                continue
            }
            guard index + 1 < args.count else {
                throw CLIError.message("missing value for \(token)")
            }
            let value = args[index + 1]
            switch key {
            case "option":
                guard let number = Int(value), number >= 1 else {
                    throw CLIError.message("--option must be a 1-based option number")
                }
                payload["option"] = number
            case "id", "choice", "footprint":
                payload[key] = value
            default:
                throw CLIError.message("unknown answer option '\(token)'")
            }
            index += 2
        }
        guard payload["id"] != nil else {
            throw CLIError.message("answer requires --id ID")
        }
        guard payload["footprint"] != nil else {
            throw CLIError.message("answer requires --footprint H from a preceding `banyanctl output`")
        }
        return payload
    }

    /// `suggest` proposes a command instead of running one: the app parks it in
    /// its sidebar and only runs it if the human approves.
    ///
    /// Required fields are checked here so a scheduled picker gets a usage error
    /// naming the missing flag, rather than a 400 from the far side of a socket.
    func parseSuggestPayload(_ args: [String]) throws -> [String: String] {
        var result: [String: String] = [:]
        var index = 0
        while index < args.count {
            let token = args[index]
            guard token.hasPrefix("--") else {
                throw CLIError.message("unexpected argument '\(token)'")
            }
            let rawKey = String(token.dropFirst(2))
            guard index + 1 < args.count else {
                throw CLIError.message("missing value for \(token)")
            }
            let value = args[index + 1]
            switch rawKey {
            case "title", "detail", "target", "key", "command", "run", "ttl":
                result[rawKey] = value
            case "cmd":
                result["command"] = value
            case "cwd":
                result["cwd"] = NSString(string: value).expandingTildeInPath
            default:
                throw CLIError.message("unknown suggest option '\(token)'")
            }
            index += 2
        }
        guard result["title"]?.isEmpty == false else {
            throw CLIError.message("suggest requires --title TEXT")
        }
        guard result["command"]?.isEmpty == false else {
            throw CLIError.message("suggest requires --command CMD")
        }
        if let run = result["run"], CommandRunMode(rawValue: run) == nil {
            throw CLIError.message(
                "--run must be one of: \(CommandRunMode.allCases.map(\.rawValue).joined(separator: ", "))"
            )
        }
        if let ttl = result["ttl"], Int(ttl) == nil {
            throw CLIError.message("--ttl must be a whole number of seconds")
        }
        return result
    }

    func parseScreenshotPayload(_ args: [String]) throws -> [String: String] {
        var result = try parsePayload(args)
        if let output = result.removeValue(forKey: "output") {
            result["path"] = output
        }
        guard result["path"]?.isEmpty == false else {
            throw CLIError.message("screenshot requires --output PATH or --path PATH")
        }
        return result
    }

    func parseAgentRunPayload(_ args: [String]) throws -> [String: String] {
        var result: [String: String] = [
            "cwd": host.currentDirectory
        ]
        var provider: CodingAgentProvider?
        var profileID: String?
        var prompt: String?
        var promptParts: [String] = []
        var commandOverride: String?
        var index = 0
        while index < args.count {
            let token = args[index]
            if token == "--" {
                promptParts.append(contentsOf: args.dropFirst(index + 1))
                break
            }
            if !token.hasPrefix("--") {
                promptParts.append(token)
                index += 1
                continue
            }

            let rawKey = String(token.dropFirst(2))
            if let flag = Self.booleanFocusFlag(for: rawKey) {
                result["focus"] = flag
                index += 1
                continue
            }
            if rawKey == "no-parent" {
                result["parent"] = ""
                result["agentParentExplicit"] = "true"
                index += 1
                continue
            }
            guard index + 1 < args.count else {
                throw CLIError.message("missing value for \(token)")
            }
            let value = args[index + 1]
            switch rawKey {
            case "agent", "provider":
                guard let parsedProvider = CodingAgentProvider(agentName: value) else {
                    throw CLIError.message("unknown agent '\(value)'")
                }
                provider = parsedProvider
            case "profile":
                guard !value.isEmpty else { throw CLIError.message("--profile requires an ID") }
                profileID = value
            case "command", "cmd":
                commandOverride = value
            case "cwd", "id", "title", "tone":
                result[rawKey] = value
            case "title-url", "titleURL":
                result["titleURL"] = value
            case "parent", "parent-id", "parentSessionID":
                result["parent"] = value
                result["agentParentExplicit"] = "true"
            case "prompt":
                prompt = value
            case "prompt-file":
                prompt = try readPromptFile(value)
            default:
                throw CLIError.message("unknown agent run option '\(token)'")
            }
            index += 2
        }

        if prompt != nil, !promptParts.isEmpty {
            throw CLIError.message("provide prompt either positionally or with --prompt/--prompt-file, not both")
        }
        if commandOverride != nil, prompt != nil || !promptParts.isEmpty {
            throw CLIError.message("--command cannot be combined with a prompt")
        }

        if let commandOverride {
            guard profileID == nil else {
                throw CLIError.message("--profile cannot be combined with --command")
            }
            result["command"] = commandOverride
            return result
        }

        guard provider != nil || profileID != nil else {
            throw CLIError.message("agent run requires --agent NAME or --profile ID")
        }
        guard provider == nil || profileID == nil else {
            throw CLIError.message("provide either --agent or --profile, not both")
        }
        let positionalPrompt = promptParts.isEmpty ? nil : promptParts.joined(separator: " ")
        result["agentProfile"] = profileID ?? provider?.rawValue
        result["agentPrompt"] = prompt ?? positionalPrompt
        if let provider {
            result["command"] = AgentLaunchCommand.command(provider: provider, prompt: prompt ?? positionalPrompt,
                ownedForSuspension: true)
        }
        return result
    }

    private func readPromptFile(_ path: String) throws -> String {
        if path == "-" {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        }
        do {
            return try String(contentsOfFile: NSString(string: path).expandingTildeInPath, encoding: .utf8)
        } catch {
            throw CLIError.message("could not read prompt file '\(path)'")
        }
    }
}
