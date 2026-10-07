import Foundation

/// Translate the persisted native binding to an interactive, exact-ID resume.
/// Never use --last, a picker, or a new start after an uncertain native start.
public enum CodexCLIFallback {
    public static func command(binding: CodexThreadBinding) throws -> String {
        try command(binding: binding, executable: "codex")
    }

    public static func command(binding: CodexThreadBinding, executable: String) throws -> String {
        let arguments = try arguments(binding: binding, executable: executable)
        var command = arguments.map(AgentLaunchCommand.shellQuote).joined(separator: " ")
        if let home = binding.codexHome {
            command = "env " + AgentLaunchCommand.shellQuote("CODEX_HOME=" + home) + " " + command
        }
        return command
    }

    /// Share exact overrides with the CLI bootstrap probe. `--help` parses
    /// flags but does not load config or reject retired permission policies.
    static func arguments(binding: CodexThreadBinding, executable: String,
                          validateOnly: Bool = false) throws -> [String] {
        guard binding.threadID != nil || !binding.creationAttempted else {
            throw CodexAppServerError.protocolViolation("Codex thread creation is uncertain. Recover its stored thread ID before switching to the CLI; starting again could lose the original thread.")
        }
        // The standalone TUI must never auto-attach to another managed daemon.
        var arguments = [executable, "--no-daemon"]
        arguments += ["-C", binding.cwd]
        var overrides = binding.settings.config
        if let model = binding.settings.model { overrides["model"] = .string(model) }
        if let provider = binding.settings.modelProvider { overrides["model_provider"] = .string(provider) }
        overrides["approval_policy"] = .string(binding.settings.approvalPolicy)
        overrides["sandbox_mode"] = .string(binding.settings.sandbox)
        for key in overrides.keys.sorted() {
            arguments += ["-c", key + "=" + (try toml(overrides[key]!))]
        }
        if validateOnly { arguments += ["features", "list"] }
        else if let threadID = binding.threadID { arguments += ["resume", threadID] }
        return arguments
    }

    private static func toml(_ value: CodexJSONValue) throws -> String {
        switch value {
        case .null:
            throw CodexAppServerError.protocolViolation("A native config override contains null, which Codex CLI cannot represent in TOML. Update the thread settings before switching to CLI.")
        case .array(let values): return "[" + (try values.map(toml)).joined(separator: ", ") + "]"
        case .object(let values):
            return "{" + (try values.keys.sorted().map {
                try toml(.string($0)) + " = " + toml(values[$0]!)
            }).joined(separator: ", ") + "}"
        default:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            return String(decoding: try encoder.encode(value), as: UTF8.self)
        }
    }
}
