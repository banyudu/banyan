import Foundation
import PuckSwift

public struct PuckTimelineLimits: Equatable, Sendable {
    public let maxItems: Int
    public let maxBytes: Int

    public init(maxItems: Int = 200, maxBytes: Int = 2 * 1_048_576) {
        self.maxItems = max(1, maxItems)
        self.maxBytes = max(1024, maxBytes)
    }
}

public enum PuckTimelineRole: String, Equatable, Sendable {
    case user
    case assistant
    case reasoning
    case tool
    case error
    case interruption
    case unknown
}

public enum PuckToolState: String, Equatable, Sendable {
    case running
    case succeeded
    case failed
    case truncated
}

public struct PuckToolActivity: Equatable, Sendable {
    public let callID: String
    public let name: String
    public let arguments: String?
    public let output: String
    public let state: PuckToolState

    public init(
        callID: String,
        name: String,
        arguments: String? = nil,
        output: String = "",
        state: PuckToolState
    ) {
        self.callID = callID
        self.name = name
        self.arguments = arguments
        self.output = output
        self.state = state
    }
}

public enum PuckTimelineContent: Equatable, Sendable {
    case user(String)
    case assistant(String)
    /// A reasoning summary. Codex summaries usually open with a bold heading.
    case reasoning(String)
    case tool(PuckToolActivity)
    case error(String)
    case interruption(String)
    case unknown(kind: String, detail: String)
}

public struct PuckTimelineItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let role: PuckTimelineRole
    public let content: PuckTimelineContent
    public let turnID: String?
    public let firstCursor: UInt64?
    public let lastCursor: UInt64?
    public let truncated: Bool
    /// Images attached to a user message: daemon-owned file paths, or a
    /// placeholder for an image kept only inline.
    public let images: [String]
    /// True while a reasoning summary or tool output is still streaming.
    public let isStreaming: Bool

    public init(
        id: String,
        role: PuckTimelineRole,
        content: PuckTimelineContent,
        turnID: String? = nil,
        firstCursor: UInt64? = nil,
        lastCursor: UInt64? = nil,
        truncated: Bool = false,
        images: [String] = [],
        isStreaming: Bool = false
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.turnID = turnID
        self.firstCursor = firstCursor
        self.lastCursor = lastCursor
        self.truncated = truncated
        self.images = images
        self.isStreaming = isStreaming
    }

    public var text: String {
        switch content {
        case .user(let text), .assistant(let text), .reasoning(let text), .error(let text), .interruption(let text):
            return text
        case .tool(let tool):
            if !tool.output.isEmpty { return tool.output }
            if let arguments = tool.arguments, !arguments.isEmpty { return arguments }
            return tool.state == .running ? "Waiting for result" : "No output"
        case .unknown(_, let detail):
            return detail
        }
    }

    public var title: String {
        switch content {
        case .user: return "You"
        case .assistant: return "Assistant"
        case .reasoning: return "Thinking"
        case .tool(let tool): return "Tool · \(tool.name) · \(tool.state.rawValue)"
        case .error: return "Error"
        case .interruption: return "Interrupted"
        case .unknown(let kind, _): return "Unknown event · \(kind)"
        }
    }

    public var retainedByteCount: Int {
        var bytes = id.utf8.count + text.utf8.count + title.utf8.count + 128
        bytes += turnID?.utf8.count ?? 0
        bytes += images.reduce(0) { $0 + $1.utf8.count }
        if case .tool(let tool) = content {
            bytes += tool.callID.utf8.count + tool.name.utf8.count
            bytes += tool.arguments?.utf8.count ?? 0
        }
        return bytes
    }
}

/// A turn-level failure or interruption. Notices stay separate from
/// conversation items so replay, history, and live delivery collapse into one
/// visible callout per underlying event.
public struct PuckTimelineNotice: Identifiable, Equatable, Sendable {
    public let id: String
    public let role: PuckTimelineRole
    public let text: String
    public let turnID: String?
    public let callID: String?
    public let firstCursor: UInt64?
    public let lastCursor: UInt64?
    public let truncated: Bool

    public init(
        id: String,
        role: PuckTimelineRole,
        text: String,
        turnID: String? = nil,
        callID: String? = nil,
        firstCursor: UInt64? = nil,
        lastCursor: UInt64? = nil,
        truncated: Bool = false
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.turnID = turnID
        self.callID = callID
        self.firstCursor = firstCursor
        self.lastCursor = lastCursor
        self.truncated = truncated
    }

    public var title: String {
        role == .interruption ? "Turn interrupted" : "Turn error"
    }
}

public struct PuckTimeline: Equatable, Sendable {
    public let items: [PuckTimelineItem]
    public let notices: [PuckTimelineNotice]
    public let usage: PuckUsage?
    /// What the latest turn is doing, for a status line: the heading of its
    /// newest reasoning summary, or the engine's reconnect notice.
    public let activity: String?

    public init(
        items: [PuckTimelineItem],
        notices: [PuckTimelineNotice] = [],
        usage: PuckUsage? = nil,
        activity: String? = nil
    ) {
        self.items = items
        self.notices = notices
        self.usage = usage
        self.activity = activity
    }
}

public extension PuckTimelineContent {
    /// The first bold heading of a reasoning summary, e.g. `**Inspecting
    /// files**`, or its first line.
    static func reasoningHeading(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("**"), let close = trimmed.dropFirst(2).range(of: "**") {
            let heading = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<close.lowerBound]
            let value = heading.trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { return value }
        }
        let firstLine = trimmed.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? trimmed
        return String(firstLine.prefix(120))
    }
}
