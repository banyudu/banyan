import AppKit
import BanyanCore
import SwiftUI

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

    /// A leaf `Image` for a native menu item, which renders only plain images —
    /// not composed views. Uses the provider's brand SVG when available so the
    /// dropdown shows the real Claude/Codex marks, falling back to an SF Symbol.
    var menuIconImage: Image {
        if let name = brandResourceName,
           let url = Bundle.module.url(forResource: name, withExtension: "svg"),
           let nsImage = NSImage(contentsOf: url) {
            nsImage.size = NSSize(width: 16, height: 16)
            return Image(nsImage: nsImage)
        }
        // Render the SF Symbol at a matching point size so it isn't visibly
        // smaller than the 16pt brand marks next to it in the menu.
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        if let symbol = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) {
            return Image(nsImage: symbol)
        }
        return Image(systemName: systemImage)
    }

    private var brandResourceName: String? {
        switch self {
        case .zsh: return nil
        case .claude: return "ClaudeLogo"
        case .codex: return "ChatGPTLogo"
        }
    }
}
