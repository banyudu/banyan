import Foundation

/// The named keys an external caller may inject into a pane.
///
/// An allowlist rather than a passthrough: `tmux send-keys` interprets its
/// non-`-l` arguments as key names, and the set of things that parses as a key is
/// much larger than the set anyone needs to answer a prompt. Widening this enum is
/// a deliberate act; forwarding an arbitrary string is not.
public enum TmuxKey: String, Sendable, Equatable, CaseIterable, Codable {
    case enter = "Enter"
    case escape = "Escape"
    case tab = "Tab"
    case backTab = "BTab"
    case space = "Space"
    case backspace = "BSpace"
    case up = "Up"
    case down = "Down"
    case left = "Left"
    case right = "Right"
    case interrupt = "C-c"

    /// Resolves a caller-supplied name, accepting the spellings a human types
    /// (`enter`, `esc`, `ctrl-c`) and nothing else.
    public init?(name: String) {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "enter", "return", "cr": self = .enter
        case "escape", "esc": self = .escape
        case "tab": self = .tab
        case "btab", "back-tab", "shift-tab": self = .backTab
        case "space": self = .space
        case "bspace", "backspace", "delete": self = .backspace
        case "up": self = .up
        case "down": self = .down
        case "left": self = .left
        case "right": self = .right
        case "c-c", "ctrl-c", "ctrl+c", "^c": self = .interrupt
        default: return nil
        }
    }
}

/// Builds the `tmux send-keys` argument vectors Banyan injects with.
///
/// Separated from `TmuxBackend` so the exact argv is unit-testable without a live
/// tmux server — the difference between "press Enter" and "type the word Enter"
/// lives entirely in these arrays.
public enum AgentInputCommand {
    /// Presses named keys. Targets the pane ID rather than the session name: a
    /// session can hold more than one pane, and only one of them is the agent's.
    public static func sendKeysArguments(paneID: String, keys: [TmuxKey]) -> [String] {
        ["send-keys", "-t", paneID] + keys.map(\.rawValue)
    }

    /// Types text verbatim. `-l` stops tmux reading the text as key names, and
    /// `--` stops it reading a leading `-` as a flag; without both, `text: "Enter"`
    /// submits the prompt and `text: "-n ..."` fails outright.
    public static func sendLiteralArguments(paneID: String, text: String) -> [String] {
        ["send-keys", "-t", paneID, "-l", "--", text]
    }
}

/// The semantic answers a delivery target may pick, as opposed to the raw key
/// stream `/input` accepts.
public enum AgentPromptChoice: String, Sendable, Equatable, CaseIterable, Codable {
    case yes
    case no
    case always

    public init?(name: String) {
        self.init(rawValue: name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}

/// Translates a chosen option into keystrokes.
public enum AgentPromptAnswer {
    /// Navigates from the cursor's current row to `option` and confirms.
    ///
    /// Arrow keys rather than digits, even when the agent numbered its list:
    /// arrow navigation is what every picker binds, so one translation covers
    /// providers whose menus ignore digit selection. `acceptsNumberKey` stays on
    /// the option as an optimization a caller may take, never as a requirement.
    public static func keystrokes(selecting option: Int, in prompt: AgentPrompt) -> [TmuxKey]? {
        guard option >= 1, option <= prompt.options.count else { return nil }
        let distance = option - prompt.selectedIndex
        let step: TmuxKey = distance >= 0 ? .down : .up
        return Array(repeating: step, count: abs(distance)) + [.enter]
    }

    /// Maps a coarse intent onto one of the prompt's actual options.
    ///
    /// Matches on the rendered label rather than on position, because position is
    /// not stable across agents or across dialogs: Claude's permission menu reads
    /// `1. Yes / 2. Yes, and don't ask again / 3. No`, while its trust dialog puts
    /// `No, exit` first. Returning nil when nothing matches is the point — a
    /// guessed row in a permission dialog is a wrong command approved.
    public static func option(for choice: AgentPromptChoice, in prompt: AgentPrompt) -> AgentPromptOption? {
        let alwaysMatches = prompt.options.filter { isAlways($0.label) }
        switch choice {
        case .always:
            return alwaysMatches.count == 1 ? alwaysMatches.first : nil
        case .yes:
            let matches = prompt.options.filter { starts($0.label, with: "yes") && !isAlways($0.label) }
            return matches.count == 1 ? matches.first : nil
        case .no:
            let matches = prompt.options.filter { starts($0.label, with: "no") }
            return matches.count == 1 ? matches.first : nil
        }
    }

    private static func starts(_ label: String, with word: String) -> Bool {
        let normalized = label.lowercased()
        guard normalized.hasPrefix(word) else { return false }
        let rest = normalized.dropFirst(word.count)
        // "No" and "No, and tell Claude…" are answers; "Nothing else" is not.
        return rest.isEmpty || !(rest.first?.isLetter ?? false)
    }

    /// Agents spell the sticky-approval row several ways, and with either kind of
    /// apostrophe depending on the renderer.
    private static func isAlways(_ label: String) -> Bool {
        let normalized = label.lowercased().replacingOccurrences(of: "’", with: "'")
        return normalized.contains("don't ask again")
            || normalized.contains("do not ask again")
            || normalized.contains("allow all")
            || normalized.contains("always")
    }
}
