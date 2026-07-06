import BanyanCore
import Foundation

let client = BanyanCtl(arguments: Array(CommandLine.arguments.dropFirst()))
client.run()

struct BanyanCtl {
    let arguments: [String]
    let baseURL = URL(string: "http://127.0.0.1:7842")!

    func run() {
        guard let command = arguments.first else {
            printHelp()
            return
        }

        do {
            switch command {
            case "spawn":
                try post("/spawn", payload: parsePayload(Array(arguments.dropFirst())))
            case "session":
                try runSessionCommand(Array(arguments.dropFirst()))
            case "agent":
                try runAgentCommand(Array(arguments.dropFirst()))
            case "mark":
                try post("/mark", payload: parsePayload(Array(arguments.dropFirst())))
            case "tick":
                try post("/tick", payload: parsePayload(Array(arguments.dropFirst())))
            case "close":
                try post("/close", payload: parsePayload(Array(arguments.dropFirst())))
            case "respawn":
                try post("/respawn", payload: parsePayload(Array(arguments.dropFirst())))
            case "restart":
                try post("/restart", payload: parsePayload(Array(arguments.dropFirst())))
            case "remove":
                try post("/remove", payload: parsePayload(Array(arguments.dropFirst())))
            case "screenshot":
                try post("/screenshot", payload: parseScreenshotPayload(Array(arguments.dropFirst())))
            case "list":
                try get("/list")
            case "window-state":
                try get("/window-state")
            case "help", "--help", "-h":
                printHelp()
            default:
                throw CLIError.message("unknown command '\(command)'")
            }
        } catch let error as CLIError {
            fputs("banyanctl: \(error.localizedDescription)\n", stderr)
            exit(error.exitCode)
        } catch {
            fputs("banyanctl: \(error.localizedDescription)\n", stderr)
            exit(ExitCode.serverUnavailable)
        }
    }

    private func runSessionCommand(_ args: [String]) throws {
        guard let subcommand = args.first else {
            throw CLIError.message("session requires a subcommand")
        }
        switch subcommand {
        case "new", "spawn":
            try post("/spawn", payload: parsePayload(Array(args.dropFirst())))
        default:
            throw CLIError.message("unknown session subcommand '\(subcommand)'")
        }
    }

    private func runAgentCommand(_ args: [String]) throws {
        guard let subcommand = args.first else {
            throw CLIError.message("agent requires a subcommand")
        }
        switch subcommand {
        case "run":
            try post("/spawn", payload: parseAgentRunPayload(Array(args.dropFirst())))
        default:
            throw CLIError.message("unknown agent subcommand '\(subcommand)'")
        }
    }

    private func parsePayload(_ args: [String]) throws -> [String: String] {
        var result: [String: String] = [:]
        var index = 0
        while index < args.count {
            let token = args[index]
            guard token.hasPrefix("--") else {
                throw CLIError.message("unexpected argument '\(token)'")
            }
            let rawKey = String(token.dropFirst(2))
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

    private func parseScreenshotPayload(_ args: [String]) throws -> [String: String] {
        var result = try parsePayload(args)
        if let output = result.removeValue(forKey: "output") {
            result["path"] = output
        }
        guard result["path"]?.isEmpty == false else {
            throw CLIError.message("screenshot requires --output PATH or --path PATH")
        }
        return result
    }

    private func parseAgentRunPayload(_ args: [String]) throws -> [String: String] {
        var result: [String: String] = [
            "cwd": FileManager.default.currentDirectoryPath
        ]
        var provider: CodingAgentProvider?
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
            case "command", "cmd":
                commandOverride = value
            case "cwd", "id", "title", "tone":
                result[rawKey] = value
            case "title-url", "titleURL":
                result["titleURL"] = value
            case "parent", "parent-id", "parentSessionID":
                result["parent"] = value
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
            result["command"] = commandOverride
            return result
        }

        guard let provider else {
            throw CLIError.message("agent run requires --agent NAME")
        }
        let positionalPrompt = promptParts.isEmpty ? nil : promptParts.joined(separator: " ")
        result["command"] = AgentLaunchCommand.command(provider: provider, prompt: prompt ?? positionalPrompt)
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

    private func get(_ path: String) throws {
        var request = URLRequest(url: baseURL.appendingPathComponent(String(path.dropFirst())))
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        try authorize(&request)
        try send(request)
    }

    private func post(_ path: String, payload: [String: String]) throws {
        var request = URLRequest(url: baseURL.appendingPathComponent(String(path.dropFirst())))
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try authorize(&request)
        var versionedPayload = payload
        versionedPayload["apiVersion"] = ControlProtocol.version
        request.httpBody = try JSONSerialization.data(withJSONObject: versionedPayload, options: [.sortedKeys])
        try send(request)
    }

    private func authorize(_ request: inout URLRequest) throws {
        let token = try ControlToken.loadOrCreate()
        request.setValue(token, forHTTPHeaderField: ControlToken.headerName)
    }

    private func send(_ request: URLRequest) throws {
        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var responseError: Error?
        var statusCode = 0

        URLSession.shared.dataTask(with: request) { data, response, error in
            responseData = data
            responseError = error
            statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            semaphore.signal()
        }.resume()
        semaphore.wait()

        if responseError != nil {
            throw CLIError.serverUnavailable
        }
        if let responseData, let text = String(data: responseData, encoding: .utf8) {
            print(text)
        }
        if statusCode >= 400 {
            throw CLIError.http(statusCode)
        }
    }

    private func printHelp() {
        print("""
        banyanctl controls a running Banyan app on localhost:7842.

        Usage:
          banyanctl spawn  [--id ID] [--title TITLE] [--title-url URL] [--cwd PATH] [--command CMD] [--cmd CMD] [--parent ID] [--tone blue]
          banyanctl session new [--id ID] [--title TITLE] [--title-url URL] [--cwd PATH] [--command CMD] [--cmd CMD] [--parent ID] [--tone blue]
          banyanctl agent run --agent codex|claude|deepseek|gemini|glm|mimo|minimax|opencode [--id ID] [--title TITLE] [--title-url URL] [--cwd PATH] [--prompt TEXT] [--prompt-file PATH] [prompt...]
          banyanctl mark   --id ID [--status running|executing|long-running-shell|subagents|need-input|asking|review|completed|failed] [--tone red] [--title TITLE] [--title-url URL]
          banyanctl tick   [--id ID]
          banyanctl close  --id ID
          banyanctl respawn --id ID
          banyanctl restart --id ID
          banyanctl remove --id ID
          banyanctl screenshot --output PATH
          banyanctl window-state
          banyanctl list
        """)
    }
}

enum CLIError: LocalizedError {
    case message(String)
    case http(Int)
    case serverUnavailable

    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        case .http(let statusCode): return "server returned HTTP \(statusCode)"
        case .serverUnavailable: return "Banyan control server is unavailable"
        }
    }

    var exitCode: Int32 {
        switch self {
        case .message: return ExitCode.badInput
        case .http(let statusCode):
            if statusCode == 401 {
                return ExitCode.badInput
            }
            if statusCode == 404 {
                return ExitCode.notFound
            }
            return ExitCode.badInput
        case .serverUnavailable: return ExitCode.serverUnavailable
        }
    }
}

enum ExitCode {
    static let success: Int32 = 0
    static let badInput: Int32 = 64
    static let notFound: Int32 = 66
    static let serverUnavailable: Int32 = 69
}
