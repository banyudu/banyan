import Foundation

public enum CodingAgentProvider: String, CaseIterable, Codable, Equatable, Identifiable {
    case claude
    case codex
    case deepseek
    case gemini
    case minimax
    case opencode
    case xiaomiMiMo
    case zai

    public var id: String {
        rawValue
    }

    public var displayName: String {
        switch self {
        case .claude:
            return "Claude"
        case .codex:
            return "Codex"
        case .deepseek:
            return "DeepSeek"
        case .gemini:
            return "Gemini"
        case .minimax:
            return "MiniMax"
        case .opencode:
            return "OpenCode"
        case .xiaomiMiMo:
            return "MiMo"
        case .zai:
            return "Z.ai"
        }
    }

    public var badgeText: String {
        switch self {
        case .claude:
            return "Cl"
        case .codex:
            return "Cx"
        case .deepseek:
            return "Ds"
        case .gemini:
            return "Ge"
        case .minimax:
            return "Mx"
        case .opencode:
            return "Oc"
        case .xiaomiMiMo:
            return "Mi"
        case .zai:
            return "Z"
        }
    }

    public var defaultExecutableName: String {
        switch self {
        case .claude:
            return "claude"
        case .codex:
            return "codex"
        case .deepseek:
            return "deepseek"
        case .gemini:
            return "gemini"
        case .minimax:
            return "minimax"
        case .opencode:
            return "opencode"
        case .xiaomiMiMo:
            return "mimo"
        case .zai:
            return "glm"
        }
    }

    public init?(agentName rawValue: String) {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        if let provider = Self.provider(forExecutable: normalized) {
            self = provider
            return
        }
        switch normalized {
        case "claude-code":
            self = .claude
        case "chatgpt", "openai":
            self = .codex
        case "google":
            self = .gemini
        case "xiaomi", "xiaomi-mimo":
            self = .xiaomiMiMo
        case "z", "zai", "z-ai", "z.ai", "glm":
            self = .zai
        default:
            return nil
        }
    }

    public static func detect(in command: String) -> CodingAgentProvider? {
        for token in shellTokens(command) {
            if let provider = provider(forExecutable: token) {
                return provider
            }
        }
        return nil
    }

    public static func isSupportedCommand(_ command: String) -> Bool {
        detect(in: command) != nil
    }

    public static func promptCandidate(in command: String, provider expectedProvider: CodingAgentProvider? = nil) -> String? {
        let tokens = shellTokens(command)
        guard let providerIndex = tokens.firstIndex(where: { token in
            guard let provider = provider(forExecutable: token) else { return false }
            return expectedProvider.map { $0 == provider } ?? true
        }) else {
            return nil
        }

        var arguments = Array(tokens.dropFirst(providerIndex + 1))
        var promptTokens: [String] = []
        while !arguments.isEmpty {
            let token = arguments.removeFirst()
            if token == "--" {
                promptTokens = arguments
                break
            }
            if token.hasPrefix("-") {
                let optionName = String(token.split(separator: "=", maxSplits: 1).first ?? "")
                if !token.contains("="), optionsTakingValue.contains(optionName), !arguments.isEmpty {
                    arguments.removeFirst()
                }
                continue
            }
            if promptSubcommands.contains(token.lowercased()), !arguments.isEmpty {
                continue
            }
            promptTokens = [token] + arguments
            break
        }

        let prompt = clean(promptTokens.joined(separator: " "))
        return prompt.isEmpty ? nil : prompt
    }

    private static func provider(forExecutable token: String) -> CodingAgentProvider? {
        let executable = URL(fileURLWithPath: token).lastPathComponent.lowercased()
        switch executable {
        case "claude":
            return .claude
        case "codex":
            return .codex
        case "deepseek", "deepseek-coder":
            return .deepseek
        case "gemini", "google-gemini":
            return .gemini
        case "glm", "z.ai", "z-ai", "zai", "zhipu", "chatglm":
            return .zai
        case "mimo", "mi-mimo", "xiaomi-mimo", "xiaomimimo":
            return .xiaomiMiMo
        case "mini-max", "minimax":
            return .minimax
        case "opencode":
            return .opencode
        default:
            return nil
        }
    }

    private static let optionsTakingValue: Set<String> = [
        "-C",
        "-c",
        "-m",
        "--add-dir",
        "--approval-mode",
        "--approval-policy",
        "--ask-for-approval",
        "--cd",
        "--config",
        "--cwd",
        "--model",
        "--profile",
        "--sandbox",
        "--sandbox-mode",
        "--system-prompt"
    ]

    private static let promptSubcommands: Set<String> = [
        "agent",
        "chat",
        "exec",
        "run"
    ]

    private static func shellTokens(_ command: String) -> [String] {
        command
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .map(cleanToken)
            .filter { !$0.isEmpty }
    }

    private static func cleanToken(_ token: String) -> String {
        token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`;,()[]{}"))
    }

    private static func clean(_ value: String) -> String {
        value.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
    }
}
