import Foundation

public enum AgentLaunchCommand {
    public static func command(
        provider: CodingAgentProvider,
        prompt: String? = nil,
        executableName: String? = nil,
        codexLaunchMode: CodexLaunchMode = .direct,
        ownedForSuspension: Bool = false
    ) -> String {
        if provider == .codex, codexLaunchMode == .appServer {
            return CodexAppServerLaunch.command(prompt: prompt)
        }
        var arguments = [executableName.flatMap(clean) ?? provider.defaultExecutableName]
        if ownedForSuspension {
            if provider == .codex { arguments += ["--no-daemon"] }
            if provider == .claude { arguments += ["--session-id", UUID().uuidString.lowercased()] }
        }
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
        if ownedForSuspension, provider == .opencode {
            arguments = ["env", "OPENCODE_DISABLE_AUTOUPDATE=true"] + arguments
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
