import Foundation

struct TmuxBackend {
    enum BackendError: LocalizedError {
        case tmuxNotFound
        case commandFailed([String], String)

        var errorDescription: String? {
            switch self {
            case .tmuxNotFound:
                return "tmux is not installed or could not be found in PATH"
            case .commandFailed(let arguments, let output):
                return "tmux \(arguments.joined(separator: " ")) failed: \(output)"
            }
        }
    }

    static let shared = TmuxBackend()
    static let socketName = "banyan"

    let executableURL: URL

    private init() {
        guard let url = Self.resolveExecutableURL() else {
            fatalError("tmux is required to run Banyan. Install it with: brew install tmux")
        }
        self.executableURL = url
    }

    static func sessionName(for id: String) -> String {
        "banyan-\(id)"
    }

    func hasSession(named name: String) -> Bool {
        (try? run(["has-session", "-t", name])) != nil
    }

    func attachArguments(for name: String) -> [String] {
        baseArguments + ["attach-session", "-t", name]
    }

    func listBanyanSessions() -> [String] {
        guard let output = try? run(["list-sessions", "-F", "#{session_name}"]) else {
            return []
        }
        return output
            .split(separator: "\n")
            .map(String.init)
            .filter { $0.hasPrefix("banyan-") }
    }

    func ensureSession(named name: String, cwd: String, command: String) throws {
        guard !hasSession(named: name) else { return }

        var arguments = ["new-session", "-d", "-s", name, "-c", cwd]
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedCommand.isEmpty {
            arguments.append(contentsOf: [shell, "-l"])
        } else {
            arguments.append(contentsOf: [shell, "-lc", trimmedCommand])
        }
        try run(arguments)
    }

    func killSession(named name: String) {
        _ = try? run(["kill-session", "-t", name])
    }

    private var baseArguments: [String] {
        ["-L", Self.socketName]
    }

    @discardableResult
    private func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = baseArguments + arguments
        process.environment = Self.processEnvironment()

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw BackendError.commandFailed(arguments, output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }

    private static func resolveExecutableURL() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/tmux",
            "/usr/local/bin/tmux",
            "/usr/bin/tmux",
            "/bin/tmux"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", "tmux"]
        process.environment = processEnvironment()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    private static func processEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let additions = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        let currentPath = environment["PATH"] ?? ""
        let merged = (additions + currentPath.split(separator: ":").map(String.init))
            .reduce(into: [String]()) { paths, path in
                if !paths.contains(path) {
                    paths.append(path)
                }
            }
            .joined(separator: ":")
        environment["PATH"] = merged
        environment.removeValue(forKey: "TMUX")
        environment.removeValue(forKey: "TMUX_PANE")
        return environment
    }
}
