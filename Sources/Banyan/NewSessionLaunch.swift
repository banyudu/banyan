import BanyanCore

/// The kind of process a new sidebar session launches. Each project's header "+"
/// button is a split control (VS Code style): the primary action spawns the
/// project's last-used kind, and a dropdown picks another. The choice is
/// remembered per project by `SessionStore`.
enum NewSessionLaunch: String, CaseIterable, Identifiable, Codable {
    case zsh
    case claude
    case codex

    var id: String { rawValue }

    /// Command handed to `SessionStore.spawn`; empty means the default login shell.
    var command: String {
        switch self {
        case .zsh: return ""
        case .claude, .codex: return rawValue
        }
    }

    var label: String {
        switch self {
        case .zsh: return "zsh"
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }

    /// The coding-agent provider this launch represents, if any (nil for a plain
    /// shell). Lets the split button reuse the shared provider icon.
    var provider: CodingAgentProvider? {
        switch self {
        case .zsh: return nil
        case .claude: return .claude
        case .codex: return .codex
        }
    }

    /// SF Symbol used when there is no provider icon to show (the plain shell).
    var systemImage: String {
        switch self {
        case .zsh: return "terminal"
        case .claude, .codex: return "sparkle"
        }
    }
}
