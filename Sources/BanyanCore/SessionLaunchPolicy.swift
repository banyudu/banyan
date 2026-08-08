import Foundation

/// Shared decisions for creating related sessions from an existing session.
public enum SessionLaunchPolicy {
    /// Quick sibling launch supports coding-agent runtimes whose command can be
    /// started without an additional prompt or configuration.
    public static func siblingRuntimeCommand(for provider: CodingAgentProvider?) -> String {
        switch provider {
        case .claude, .codex:
            return provider?.defaultExecutableName ?? ""
        case .opencode:
            return "opencode"
        case .deepseek:
            // DeepSeek sessions currently run through OpenCode. Preserve the
            // marker so the new session keeps the same provider identity.
            return "BANYAN_AGENT_PROVIDER=deepseek opencode"
        default:
            return ""
        }
    }
}
