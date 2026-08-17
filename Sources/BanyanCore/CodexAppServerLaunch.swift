import Foundation

/// Chooses whether a Banyan Codex terminal talks directly to Codex or through
/// the local managed app-server. App-server mode is deliberately opt-in while
/// the underlying Codex transport remains experimental.
public enum CodexLaunchMode: String, Sendable, Codable {
    case direct
    case appServer
}

/// Builds interactive Codex commands that use the local managed app-server.
///
/// This is intentionally different from `codex exec`: the latter is
/// non-interactive and cannot continue a conversation in Banyan's terminal.
/// The remote-control daemon owns the shared thread lifecycle while the TUI is
/// a client connected over the local Unix socket.
public enum CodexAppServerLaunch {
    public static let localEndpoint = "unix://"

    public static func command(prompt: String? = nil) -> String {
        var arguments: [String] = []
        if let prompt = clean(prompt) {
            arguments.append(prompt)
        }
        return interactiveCommand(arguments: arguments)
    }

    public static func resumeCommand(
        sourceID: String,
        cwd: String,
        prompt: String? = nil
    ) -> String {
        var arguments = ["resume", "-C", cwd, sourceID]
        if let prompt = clean(prompt) {
            arguments.append(prompt)
        }
        return interactiveCommand(arguments: arguments)
    }

    /// Keeps per-session provenance in the persisted shell command. It lets a
    /// closed session reconnect to the same app-server mode even after the
    /// preference has subsequently been changed.
    public static func isAppServerCommand(_ command: String) -> Bool {
        command.contains("'codex' '--remote' 'unix://'")
    }

    /// Rewrites only Banyan's canonical direct-Codex commands. This covers
    /// `banyanctl agent run --agent codex` without taking ownership of an
    /// arbitrary custom shell command entered in the session sheet.
    public static func upgradedDirectCommand(_ command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "codex" {
            return interactiveCommand(arguments: [])
        }
        let canonicalPrefix = "'codex' "
        guard trimmed.hasPrefix(canonicalPrefix) else { return nil }
        let suffix = String(trimmed.dropFirst(canonicalPrefix.count))
        return daemonStartCommand + " && exec " + remoteTUICommand + " " + suffix
    }

    private static func interactiveCommand(arguments: [String]) -> String {
        daemonStartCommand + " && exec " + remoteTUICommand(arguments: arguments)
    }

    private static var daemonStartCommand: String {
        ["codex", "remote-control", "start"]
            .map(AgentLaunchCommand.shellQuote)
            .joined(separator: " ")
    }

    private static var remoteTUICommand: String {
        remoteTUICommand(arguments: [])
    }

    private static func remoteTUICommand(arguments: [String]) -> String {
        (["codex", "--remote", localEndpoint] + arguments)
            .map(AgentLaunchCommand.shellQuote)
            .joined(separator: " ")
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
