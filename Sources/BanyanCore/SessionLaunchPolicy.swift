import Foundation

/// Shared decisions for creating related sessions from an existing session.
public enum SessionLaunchPolicy {
    /// Quick sibling launch supports only the coding-agent runtimes whose
    /// command can be started without an additional prompt or configuration.
    public static func siblingRuntimeCommand(for provider: CodingAgentProvider?) -> String {
        switch provider {
        case .claude, .codex:
            return provider?.defaultExecutableName ?? ""
        default:
            return ""
        }
    }
}
