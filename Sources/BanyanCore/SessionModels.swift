import Foundation

public enum SessionStatus: String, CaseIterable, Identifiable, Codable, Sendable {
    case running
    case executing
    case longRunningShell = "long-running-shell"
    case subagents
    case needInput = "need-input"
    case asking
    case review
    case completed
    case failed
    case closed

    public var id: String { rawValue }

    public var isCodingAgentIdle: Bool {
        switch self {
        case .needInput, .asking, .review: return true
        case .running, .executing, .longRunningShell, .subagents, .completed, .failed, .closed: return false
        }
    }

    public var label: String {
        switch self {
        case .running: return "Running"
        case .executing: return "Executing"
        case .longRunningShell: return "Long Shell"
        case .subagents: return "Subagents"
        case .needInput: return "Need Input"
        case .asking: return "Asking"
        case .review: return "Review"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .closed: return "Closed"
        }
    }

    public var emoji: String {
        switch self {
        case .running: return "⚙️"
        case .executing: return "🔧"
        case .longRunningShell: return "⏳"
        case .subagents: return "🧩"
        case .needInput: return "✋"
        case .asking: return "❓"
        case .review: return "👀"
        case .completed: return "✅"
        case .failed: return "❌"
        case .closed: return "📦"
        }
    }

    public var priority: Int {
        switch self {
        case .asking: return 0
        case .needInput: return 1
        case .failed: return 2
        case .longRunningShell: return 3
        case .subagents: return 4
        case .review: return 5
        case .executing: return 6
        case .running: return 7
        case .completed: return 8
        case .closed: return 9
        }
    }
}

public enum SessionTone: String, CaseIterable, Identifiable, Codable, Sendable {
    case neutral
    case blue
    case green
    case yellow
    case red
    case purple

    public var id: String { rawValue }

    public var label: String {
        rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }
}

public enum SortMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case manual
    case status
    case updated
    case title

    public var id: String { rawValue }

    public var label: String {
        rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }
}
