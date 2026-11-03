import BanyanCore
import Foundation

/// Session actions Banyan interprets when they are submitted from a terminal
/// coding agent's own prompt. Agent-owned commands such as `/clear`, `/compact`,
/// and `/review` deliberately do not appear here; those are already handled by
/// the running TUI and must continue to reach it unchanged.
enum TerminalSlashCommand: String, CaseIterable, Sendable {
    case new = "/new"
    case newRoot = "/new-root"
    case newTerminal = "/new-terminal"
    case scratch = "/scratch"
    case find = "/find"
    case rename = "/rename"
    case close = "/close"
    case sessions = "/sessions"
    case next = "/next"
    case previous = "/previous"
    case nextAttention = "/attention"
    case previousAttention = "/previous-attention"
    case workable = "/workable"

    var aliases: [String] {
        switch self {
        case .previous:
            return ["/prev"]
        case .nextAttention:
            return ["/next-attention"]
        case .previousAttention:
            return ["/prev-attention"]
        default:
            return []
        }
    }

    static func parse(_ input: String) -> TerminalSlashCommand? {
        let normalized = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return allCases.first { command in
            command.rawValue == normalized || command.aliases.contains(normalized)
        }
    }
}

/// Keeps Banyan shortcuts out of plain shells and historical rows. A detected
/// coding-agent prompt owns slash syntax, so the app may interpret that subset.
enum TerminalSlashCommandPolicy {
    static func canHandle(
        provider: CodingAgentProvider?,
        isImportedHistory: Bool,
        status: SessionStatus
    ) -> Bool {
        provider != nil && !isImportedHistory && status != .closed
    }
}
