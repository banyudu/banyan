import AppKit
import SwiftUI

enum SessionStatus: String, CaseIterable, Identifiable, Codable {
    case running
    case needInput = "need-input"
    case review
    case completed
    case failed
    case closed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .running: return "Running"
        case .needInput: return "Need Input"
        case .review: return "Review"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .closed: return "Closed"
        }
    }

    var systemImage: String {
        switch self {
        case .running: return "play.fill"
        case .needInput: return "hand.raised.fill"
        case .review: return "eye.fill"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .closed: return "archivebox.fill"
        }
    }

    var priority: Int {
        switch self {
        case .needInput: return 0
        case .failed: return 1
        case .review: return 2
        case .running: return 3
        case .completed: return 4
        case .closed: return 5
        }
    }
}

enum SessionTone: String, CaseIterable, Identifiable, Codable {
    case neutral
    case blue
    case green
    case yellow
    case red
    case purple

    var id: String { rawValue }

    var label: String {
        rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }

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

enum SortMode: String, CaseIterable, Identifiable {
    case manual
    case status
    case updated
    case title

    var id: String { rawValue }

    var label: String {
        rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }
}
