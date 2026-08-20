import Foundation

public enum AgentLaunchCommand {
    public static func command(
        provider: CodingAgentProvider,
        prompt: String? = nil,
        executableName: String? = nil,
        codexLaunchMode: CodexLaunchMode = .direct
    ) -> String {
        if provider == .codex, codexLaunchMode == .appServer {
            return CodexAppServerLaunch.command(prompt: prompt)
        }
        var arguments = [executableName.flatMap(clean) ?? provider.defaultExecutableName]
        switch provider {
        case .hunyuan:
            arguments.append("--agent")
            arguments.append("hy3")
        case .muse:
            arguments.append("--agent")
            arguments.append("muse-spark")
        default:
            break
        }
        if let prompt = clean(prompt) {
            arguments.append(prompt)
        }
        return arguments.map(shellQuote).joined(separator: " ")
    }

    public static func shellQuote(_ value: String) -> String {
        if value.isEmpty {
            return "''"
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
