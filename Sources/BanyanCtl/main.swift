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
            case "close":
                try post("/close", payload: parsePayload(Array(arguments.dropFirst())))
            case "remove":
                try post("/remove", payload: parsePayload(Array(arguments.dropFirst())))
            case "list":
                try get("/list")
            case "help", "--help", "-h":
                printHelp()
            default:
                throw CLIError.message("unknown command '\(command)'")
            }
        } catch {
            fputs("banyanctl: \(error.localizedDescription)\n", stderr)
            exit(1)
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
            let key = rawKey == "cmd" ? "command" : rawKey
            guard index + 1 < args.count else {
                throw CLIError.message("missing value for \(token)")
            }
            result[key] = args[index + 1]
            index += 2
        }
        return result
    }

    private func get(_ path: String) throws {
        var request = URLRequest(url: baseURL.appendingPathComponent(String(path.dropFirst())))
        request.httpMethod = "GET"
        try send(request)
    }

    private func post(_ path: String, payload: [String: String]) throws {
        var request = URLRequest(url: baseURL.appendingPathComponent(String(path.dropFirst())))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try send(request)
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

        if let responseError {
            throw responseError
        }
        if let responseData, let text = String(data: responseData, encoding: .utf8) {
            print(text)
        }
        if statusCode >= 400 {
            throw CLIError.message("server returned HTTP \(statusCode)")
        }
    }

    private func printHelp() {
        print("""
        banyanctl controls a running Banyan app on localhost:7842.

        Usage:
          banyanctl spawn  [--id ID] [--title TITLE] [--cwd PATH] [--command CMD] [--cmd CMD] [--tone blue]
          banyanctl mark   --id ID [--status running|need-input|review|completed|failed] [--tone red] [--title TITLE]
          banyanctl close  --id ID
          banyanctl remove --id ID
          banyanctl list
        """)
    }
}

enum CLIError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        }
    }
}
