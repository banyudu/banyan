import BanyanCore
import Foundation

struct TmuxPaneSnapshot {
    let paneID: String
    let rootPID: Int
    let currentCommand: String
    let currentPath: String
    let isDead: Bool
    let isInMode: Bool
}

struct TmuxBackend: Sendable {
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

    func primaryPaneSnapshot(named name: String) -> TmuxPaneSnapshot? {
        let format = [
            "#{pane_id}",
            "#{pane_pid}",
            "#{pane_current_command}",
            "#{pane_current_path}",
            "#{pane_dead}",
            "#{pane_in_mode}"
        ].joined(separator: "\t")
        guard let output = try? run(["list-panes", "-t", name, "-F", format]),
              let line = output.split(separator: "\n", omittingEmptySubsequences: true).first
        else {
            return nil
        }

        let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 6, let rootPID = Int(parts[1]) else {
            return nil
        }
        return TmuxPaneSnapshot(
            paneID: parts[0],
            rootPID: rootPID,
            currentCommand: parts[2],
            currentPath: parts[3],
            isDead: parts[4] == "1",
            isInMode: parts[5] == "1"
        )
    }

    func captureVisibleText(paneID: String, lineLimit: Int = 80) -> String {
        let start = "-\(max(1, lineLimit))"
        return (try? run(["capture-pane", "-p", "-J", "-t", paneID, "-S", start])) ?? ""
    }

    func captureCurrentVisibleText(paneID: String) -> String {
        (try? run(["capture-pane", "-p", "-J", "-t", paneID])) ?? ""
    }

    /// Scrolls the pane's history using tmux's own copy-mode, so the scrollback the
    /// user sees is tmux's (already held, ~35 MB for a whole server) instead of a
    /// duplicated SwiftTerm buffer (~123 MB per terminal at a 20k limit).
    ///
    /// Runs off the main thread: each call is a `tmux` subprocess, and wheel events
    /// arrive faster than one can complete. `scrollQueue` is serial so the copy-mode
    /// entry always precedes the scroll commands it enables, and so successive
    /// scrolls apply in gesture order.
    ///
    /// `copy-mode -e` exits automatically once the user scrolls back to the bottom,
    /// which keeps the pane out of a modal state we would otherwise have to unwind.
    func scrollHistory(paneID: String, lines: Int, up: Bool) {
        guard lines > 0 else { return }
        scrollQueue.async { [self] in
            if up {
                // Harmless if the pane is already in copy-mode.
                _ = try? run(["copy-mode", "-e", "-t", paneID])
            }
            // Fails harmlessly when scrolling down outside copy-mode (nothing to scroll).
            _ = try? run([
                "send-keys", "-t", paneID, "-X", "-N", String(lines),
                up ? "scroll-up" : "scroll-down"
            ])
        }
    }

    func refreshClients(attachedTo name: String) {
        guard let output = try? run(["list-clients", "-t", name, "-F", "#{client_name}"]) else {
            return
        }
        for client in output.split(separator: "\n").map(String.init) where !client.isEmpty {
            _ = try? run(["refresh-client", "-t", client, "-S"])
        }
    }

    func ensureSession(named name: String, cwd: String, command: String) throws {
        // Most global options only need to be applied when the server starts.
        // The server lives as long as it has ≥1 session, but terminal capability
        // settings must also be migrated when the app is upgraded underneath an
        // existing server.
        if !isServerRunning() {
            configureServerEnvironment()
            configureServerOptions()
        } else {
            configureServerTerminalColors()
        }
        guard !hasSession(named: name) else {
            configureSessionOptions(named: name)
            return
        }

        var arguments = ["new-session", "-d", "-s", name, "-c", cwd]
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedCommand.isEmpty {
            arguments.append(contentsOf: [shell, "-l"])
        } else {
            arguments.append(contentsOf: [shell, "-lc", trimmedCommand])
        }
        do {
            try run(arguments)
        } catch {
            // A concurrent ensureSession (e.g. background start racing a later
            // foreground attach) may have already created it; tolerate that.
            guard hasSession(named: name) else { throw error }
        }
        configureSessionOptions(named: name)
    }

    func killSession(named name: String) {
        _ = try? run(["kill-session", "-t", name])
    }

    /// A banyan tmux server exits once its last session closes, so a server that
    /// answers `list-sessions` is one we already configured when its first session
    /// was created.
    private func isServerRunning() -> Bool {
        (try? run(["list-sessions", "-F", "#{session_name}"])) != nil
    }

    private func configureSessionOptions(named name: String) {
        _ = try? run(["set-option", "-t", name, "status", "off"])
        _ = try? run(["set-option", "-t", name, "mouse", "on"])
        _ = try? run(["set-option", "-t", name, "history-limit", "20000"])
    }

    private func configureServerOptions() {
        _ = try? run(["set-option", "-g", "status", "off"])
        _ = try? run(["set-option", "-g", "mouse", "on"])
        _ = try? run(["set-option", "-g", "history-limit", "20000"])
        _ = try? run(["set-option", "-g", "default-terminal", "tmux-256color"])
        configureServerTerminalColors()
    }

    private func configureServerTerminalColors() {
        _ = try? run(["set-option", "-g", "terminal-overrides", "tmux-256color:RGB,xterm-256color:RGB"])
    }

    private func configureServerEnvironment() {
        _ = try? run(["set-environment", "-gu", "NO_COLOR"])
        _ = try? run(["set-environment", "-g", "COLORTERM", "truecolor"])
        _ = try? run(["set-environment", "-g", "CLICOLOR", "1"])
        _ = try? run(["set-environment", "-g", "CLICOLOR_FORCE", "1"])
        _ = try? run(["set-environment", "-g", "FORCE_COLOR", "3"])
    }

    private var baseArguments: [String] {
        ["-L", Self.socketName]
    }

    /// Safety cap so a wedged tmux server can never hang a supervisor tick (or the
    /// main thread on foreground start) forever. Raw `Process.waitUntilExit()` can
    /// miss the child's termination notification and block indefinitely — the cause
    /// of multi-minute `supervisor.tick` outliers. `SubprocessRunner` completes via
    /// `terminationHandler` and enforces this timeout instead.
    private static let commandTimeout: TimeInterval = 10

    /// Serializes copy-mode scroll commands off the main thread — see `scrollHistory`.
    private let scrollQueue = DispatchQueue(label: "dev.banyudu.banyan.tmux-scroll")

    @discardableResult
    private func run(_ arguments: [String]) throws -> String {
        let output = try SubprocessRunner.run(
            arguments: [executableURL.path] + baseArguments + arguments,
            cwd: NSHomeDirectory(),
            environment: Self.processEnvironment(),
            timeout: Self.commandTimeout
        )
        let stdout = String(decoding: output.standardOutput, as: UTF8.self)
        guard output.terminationStatus == 0 else {
            let stderr = String(decoding: output.standardError, as: UTF8.self)
            let message = (stderr.isEmpty ? stdout : stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            throw BackendError.commandFailed(arguments, message)
        }
        return stdout
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
        environment.removeValue(forKey: "NO_COLOR")
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["CLICOLOR"] = "1"
        environment["CLICOLOR_FORCE"] = "1"
        environment["FORCE_COLOR"] = "3"
        return environment
    }
}
