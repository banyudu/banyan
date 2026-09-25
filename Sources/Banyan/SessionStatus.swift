import AppKit
import BanyanCore
import SwiftUI

// Presentation-only mapping for the macOS frontend. The shared session models
// deliberately remain free of AppKit and SwiftUI so a Linux frontend can reuse
// the same status values and ordering rules.
extension SessionTone {
    var nsColor: NSColor {
        switch self {
        case .neutral: return .secondaryLabelColor
        case .blue: return .systemBlue
        case .green: return .systemGreen
        case .yellow: return .systemYellow
        case .red: return .systemRed
        case .purple: return .systemPurple
        }
    }

    var backgroundColor: Color {
        Color(nsColor: nsColor.withAlphaComponent(0.16))
    }
}

extension CodingAgentProvider {
    /// Brand tint for the sidebar's jump-key badge. Providers with a
    /// recognizable logo colour use it — so a session reads as the agent it
    /// runs, not the runtime that happens to host it (a DeepSeek launch under
    /// Codex keeps DeepSeek's blue rather than borrowing Codex's cyan). The
    /// rest stay neutral: the tint means identity, not decoration.
    var brandTint: Color {
        switch self {
        case .claude:
            return .orange
        case .codex:
            return .cyan
        // DeepSeek's logo blue (#4d6bfe), taken from DeepSeekLogo.svg.
        case .deepseek:
            return Color.linearHex("4d6bfe")
        case .gemini, .hunyuan, .minimax, .muse, .opencode, .qwen, .xiaomiMiMo, .zai:
            return .secondary
        }
    }
}
