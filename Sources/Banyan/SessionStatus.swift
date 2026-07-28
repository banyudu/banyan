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
