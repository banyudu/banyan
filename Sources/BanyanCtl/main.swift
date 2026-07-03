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
            case "mark":
                try post("/mark", payload: parsePayload(Array(arguments.dropFirst())))
            case "tick":
                try post("/tick", payload: parsePayload(Array(arguments.dropFirst())))
            case "close":
                try post("/close", payload: parsePayload(Array(arguments.dropFirst())))
            case "respawn":
                try post("/respawn", payload: parsePayload(Array(arguments.dropFirst())))
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
          banyanctl spawn  [--id ID] [--title TITLE] [--cwd PATH] [--command CMD] [--cmd CMD] [--parent ID] [--tone blue]
          banyanctl mark   --id ID [--status running|executing|long-running-shell|subagents|need-input|asking|review|completed|failed] [--tone red] [--title TITLE]
          banyanctl tick   [--id ID]
          banyanctl close  --id ID
          banyanctl respawn --id ID
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
