import Foundation

public enum CodingAgentProvider: String, CaseIterable, Codable, Equatable, Identifiable, Sendable {
    case claude
    case codex
    case deepseek
    case gemini
    case hunyuan
    case minimax
    case muse
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
        case .hunyuan:
            return "Hunyuan"
        case .minimax:
            return "MiniMax"
        case .muse:
            return "Muse Spark"
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
        case .hunyuan:
            return "Hy"
        case .minimax:
            return "Mx"
        case .muse:
            return "Ms"
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
        case .hunyuan:
            return "opencode"
        case .minimax:
            return "minimax"
        case .muse:
            return "opencode"
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
        case "hy", "hy3", "hunyuan", "tencent", "tencent-hy", "tencent-hunyuan":
            self = .hunyuan
        case "xiaomi", "xiaomi-mimo":
            self = .xiaomiMiMo
        case "z", "zai", "z-ai", "z.ai", "glm":
            self = .zai
        case "muse", "muse-spark", "muse spark", "meta-muse", "muse-spark-1.2":
            self = .muse
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

    /// Maps an OpenCode model selection to Banyan's provider icon vocabulary.
    /// Model IDs are preferred because OpenCode's routing provider can be a
    /// gateway such as `opencode-go`, rather than the model vendor.
    public static func runtimeProvider(modelID: String, providerID: String?) -> CodingAgentProvider? {
        let candidates = [modelID, providerID ?? ""]
            .map { $0.lowercased() }
            .filter { !$0.isEmpty }
        for candidate in candidates {
            if candidate.contains("deepseek") { return .deepseek }
            if candidate.contains("anthropic") || candidate.contains("claude") { return .claude }
            if candidate.contains("openai") || candidate.contains("gpt") || candidate.contains("o1") || candidate.contains("o3") || candidate.contains("o4") { return .codex }
            if candidate.contains("google") || candidate.contains("gemini") { return .gemini }
            if candidate.contains("hunyuan") || candidate.contains("hy3") || candidate == "hy" || candidate.contains("tencent") { return .hunyuan }
            if candidate.contains("muse") && candidate.contains("spark") { return .muse }
            if candidate == "muse" || candidate.contains("muse-spark") { return .muse }
            if candidate.contains("minimax") || candidate.contains("mini-max") { return .minimax }
            if candidate.contains("xiaomi") || candidate.contains("mimo") { return .xiaomiMiMo }
            if candidate.contains("zhipu") || candidate.contains("z.ai") || candidate.contains("zai") || candidate.contains("glm") { return .zai }
        }
        return nil
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
        // The DeepSeek picker launches OpenCode with an environment marker so
        // the session keeps its DeepSeek identity even though the executable is
        // `opencode`. It is launch metadata, not a user prompt.
        if isProviderMarker(tokens[providerIndex]), arguments.first == "opencode" {
            arguments.removeFirst()
        }
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
        if isProviderMarker(executable) {
            switch executable.dropFirst("banyan_agent_provider=".count) {
            case "deepseek":
                return .deepseek
            default:
                return nil
            }
        }
        switch executable {
        case "claude":
            return .claude
        case "codex":
            return .codex
        case "deepseek", "deepseek-coder":
            return .deepseek
        case "gemini", "google-gemini":
            return .gemini
        case "hunyuan", "hy", "hy3", "tencent-hy", "tencent-hunyuan":
            return .hunyuan
        case "glm", "z.ai", "z-ai", "zai", "zhipu", "chatglm":
            return .zai
        case "mimo", "mi-mimo", "xiaomi-mimo", "xiaomimimo":
            return .xiaomiMiMo
        case "mini-max", "minimax":
            return .minimax
        case "muse", "muse-spark", "meta-muse":
            return .muse
        case "opencode":
            return .opencode
        default:
            return nil
        }
    }

    private static func isProviderMarker(_ token: String) -> Bool {
        URL(fileURLWithPath: token).lastPathComponent.lowercased()
            .hasPrefix("banyan_agent_provider=")
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
        var tokens: [String] = []
        var current = ""
        var isInSingleQuote = false
        var isInDoubleQuote = false
        var isEscaping = false

        func appendCurrentToken() {
            let token = cleanToken(current)
            if !token.isEmpty {
                tokens.append(token)
            }
            current = ""
        }

        for character in command {
            if isEscaping {
                current.append(character)
                isEscaping = false
                continue
            }

            if character == "\\", !isInSingleQuote {
                isEscaping = true
                continue
            }

            if character == "'", !isInDoubleQuote {
                isInSingleQuote.toggle()
                continue
            }

            if character == "\"", !isInSingleQuote {
                isInDoubleQuote.toggle()
                continue
            }

            if character.isWhitespace, !isInSingleQuote, !isInDoubleQuote {
                appendCurrentToken()
                continue
            }

            current.append(character)
        }

        if isEscaping {
            current.append("\\")
        }
        appendCurrentToken()
        return tokens
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
