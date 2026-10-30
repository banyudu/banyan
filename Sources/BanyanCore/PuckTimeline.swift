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

    public init(
        id: String,
        role: PuckTimelineRole,
        content: PuckTimelineContent,
        turnID: String? = nil,
        firstCursor: UInt64? = nil,
        lastCursor: UInt64? = nil,
        truncated: Bool = false
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.turnID = turnID
        self.firstCursor = firstCursor
        self.lastCursor = lastCursor
        self.truncated = truncated
    }

    public var text: String {
        switch content {
        case .user(let text), .assistant(let text), .error(let text), .interruption(let text):
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
        case .tool(let tool): return "Tool · \(tool.name) · \(tool.state.rawValue)"
        case .error: return "Error"
        case .interruption: return "Interrupted"
        case .unknown(let kind, _): return "Unknown event · \(kind)"
        }
    }

    public var retainedByteCount: Int {
        var bytes = id.utf8.count + text.utf8.count + title.utf8.count + 128
        bytes += turnID?.utf8.count ?? 0
        if case .tool(let tool) = content {
            bytes += tool.callID.utf8.count + tool.name.utf8.count
            bytes += tool.arguments?.utf8.count ?? 0
        }
        return bytes
    }
}

public struct PuckTimeline: Equatable, Sendable {
    public let items: [PuckTimelineItem]
    public let usage: PuckUsage?

    public init(items: [PuckTimelineItem], usage: PuckUsage? = nil) {
        self.items = items
        self.usage = usage
    }
}

public enum PuckTimelineProjection {
    public static func project(
        history: [PuckHistoryItem],
        events: [PuckSessionEvent],
        limits: PuckTimelineLimits = PuckTimelineLimits()
    ) -> PuckTimeline {
        var builder = Builder(limits: limits)
        builder.append(history: history)
        builder.append(events: events)
        return builder.finish()
    }
}

private struct Builder {
    private struct Draft {
        var id: String
        var role: PuckTimelineRole
        var content: PuckTimelineContent
        var turnID: String?
        var firstCursor: UInt64?
        var lastCursor: UInt64?
        var truncated: Bool
        var stableKeys: [String]
        var toolCallID: String?
        var fromHistory: Bool
        var matchedLive: Bool
        var isStream: Bool

        var text: String {
            switch content {
            case .user(let text), .assistant(let text), .error(let text), .interruption(let text):
                return text
            case .tool(let tool):
                return tool.output.isEmpty ? tool.arguments ?? "" : tool.output
            case .unknown(_, let detail):
                return detail
            }
        }

        var retainedByteCount: Int {
            var bytes = id.utf8.count + text.utf8.count + 128
            bytes += turnID?.utf8.count ?? 0
            if case .tool(let tool) = content {
                bytes += tool.callID.utf8.count + tool.name.utf8.count
                bytes += tool.arguments?.utf8.count ?? 0
            }
            return bytes
        }

        var timelineItem: PuckTimelineItem {
            PuckTimelineItem(
                id: id,
                role: role,
                content: content,
                turnID: turnID,
                firstCursor: firstCursor,
                lastCursor: lastCursor,
                truncated: truncated
            )
        }
    }

    private static let ignoredKinds: Set<String> = [
        "turn_started", "turn_done", "usage", "hibernated", "approval_pending",
        "approval_decided", "blocked_on_question", "question_answered", "presence_changed",
        "history_changed", "lagged", "autonomy_parked", "merge_decision_needed", "plan_updated",
    ]

    private let limits: PuckTimelineLimits
    private var drafts: [Draft] = []
    private var stableIndex: [String: Int] = [:]
    private var toolIndex: [String: Int] = [:]
    private var seenCursors: Set<UInt64> = []
    private var streamIndex: Int?
    private var usage: PuckUsage?

    init(limits: PuckTimelineLimits) {
        self.limits = limits
    }

    mutating func append(history: [PuckHistoryItem]) {
        for item in history { append(historyItem: item) }
        enforceLimits()
    }

    mutating func append(events: [PuckSessionEvent]) {
        for event in events { append(event: event) }
        enforceLimits()
    }

    mutating func finish() -> PuckTimeline {
        PuckTimeline(items: drafts.map(\.timelineItem), usage: usage)
    }

    private mutating func append(historyItem item: PuckHistoryItem) {
        guard stableIndex[item.id] == nil else { return }
        let text = item.text
        let content: PuckTimelineContent
        let role: PuckTimelineRole
        switch item.kind.lowercased() {
        case "user", "user_message":
            role = .user
            content = .user(text)
        case "assistant", "agent", "agent_message", "assistant_message", "plan":
            role = .assistant
            content = .assistant(text)
        case "tool", "tool_result", "tool_start", "command", "file_change":
            role = .tool
            content = .tool(PuckToolActivity(
                callID: item.id,
                name: "tool",
                output: text,
                state: .succeeded
            ))
        case "error", "turn_error", "persistence_error", "audit_error":
            role = errorRole(for: text)
            content = role == .interruption ? .interruption(text) : .error(text)
        default:
            role = .unknown
            content = .unknown(kind: item.kind, detail: text)
        }
        let toolCallID = role == .tool ? item.id : nil
        let index = appendDraft(Draft(
            id: role == .tool ? "tool:\(item.id)" : "item:\(item.id)",
            role: role,
            content: content,
            turnID: item.turnID,
            firstCursor: nil,
            lastCursor: nil,
            truncated: item.truncated,
            stableKeys: [item.id],
            toolCallID: toolCallID,
            fromHistory: true,
            matchedLive: false,
            isStream: false
        ))
        if let toolCallID { toolIndex[toolCallID] = index }
    }

    private mutating func append(event: PuckSessionEvent) {
        if !event.transient, event.cursor > 0, !seenCursors.insert(event.cursor).inserted {
            return
        }
        switch event.kind {
        case "turn_started":
            streamIndex = nil
        case "turn_done":
            streamIndex = nil
        case "usage":
            usage = event.usage ?? usage
        case "text_delta":
            appendTextDelta(event)
        case "assistant_message":
            appendMessage(role: .assistant, event: event, text: event.text ?? "")
        case "user_message":
            appendMessage(role: .user, event: event, text: event.text ?? "")
        case "tool_start":
            appendToolStart(event)
        case "tool_result":
            appendToolResult(event)
        case "hosted_call":
            appendHostedCall(event)
        case "turn_error", "persistence_error", "audit_error":
            let text = event.message ?? event.text ?? "Turn failed"
            let role = errorRole(for: text)
            let content: PuckTimelineContent = role == .interruption ? .interruption(text) : .error(text)
            _ = appendDraft(Draft(
                id: "event:\(event.cursor)",
                role: role,
                content: content,
                turnID: event.turnID,
                firstCursor: event.cursor,
                lastCursor: event.cursor,
                truncated: event.truncated,
                stableKeys: [],
                toolCallID: nil,
                fromHistory: false,
                matchedLive: false,
                isStream: false
            ))
        default:
            guard !Self.ignoredKinds.contains(event.kind) else { return }
            appendUnknown(event)
        }
        enforceLimits()
    }

    private mutating func appendTextDelta(_ event: PuckSessionEvent) {
        guard let delta = event.text, !delta.isEmpty else { return }
        if let index = streamIndex, drafts.indices.contains(index), drafts[index].isStream,
           case .assistant(let existing) = drafts[index].content {
            drafts[index].content = .assistant(existing + delta)
            drafts[index].lastCursor = event.cursor
            return
        }
        let index = appendDraft(Draft(
            id: "stream:\(event.cursor)",
            role: .assistant,
            content: .assistant(delta),
            turnID: event.turnID,
            firstCursor: event.cursor,
            lastCursor: event.cursor,
            truncated: event.truncated,
            stableKeys: [],
            toolCallID: nil,
            fromHistory: false,
            matchedLive: false,
            isStream: true
        ))
        streamIndex = index
    }

    private mutating func appendMessage(
        role: PuckTimelineRole,
        event: PuckSessionEvent,
        text: String
    ) {
        let keys = stableKeys(for: event)
        if let index = keys.compactMap({ stableIndex[$0] }).first {
            if role == .assistant, let streamIndex, drafts.indices.contains(streamIndex),
               drafts[streamIndex].isStream, drafts[streamIndex].text == text {
                removeDraft(at: streamIndex)
            }
            drafts[index].matchedLive = true
            registerStableKeys(keys, at: index)
            return
        }
        if keys.isEmpty, let index = fallbackHistoryIndex(role: role, text: text, turnID: event.turnID) {
            if role == .assistant, let streamIndex, drafts.indices.contains(streamIndex),
               drafts[streamIndex].isStream, drafts[streamIndex].text == text {
                removeDraft(at: streamIndex)
            }
            drafts[index].matchedLive = true
            return
        }

        let content: PuckTimelineContent = role == .user ? .user(text) : .assistant(text)
        if role == .assistant, let streamIndex, drafts.indices.contains(streamIndex),
           drafts[streamIndex].isStream {
            drafts[streamIndex].content = content
            drafts[streamIndex].lastCursor = event.cursor
            drafts[streamIndex].truncated = event.truncated
            drafts[streamIndex].isStream = false
            if let key = keys.first {
                drafts[streamIndex].id = "item:\(key)"
            }
            registerStableKeys(keys, at: streamIndex)
            registerTools(at: streamIndex)
            self.streamIndex = nil
            return
        }

        let id = keys.first.map { "item:\($0)" } ?? "event:\(event.cursor)"
        let index = appendDraft(Draft(
            id: id,
            role: role,
            content: content,
            turnID: event.turnID,
            firstCursor: event.cursor,
            lastCursor: event.cursor,
            truncated: event.truncated,
            stableKeys: keys,
            toolCallID: nil,
            fromHistory: false,
            matchedLive: false,
            isStream: false
        ))
        registerStableKeys(keys, at: index)
    }

    private mutating func appendToolStart(_ event: PuckSessionEvent) {
        let keys = stableKeys(for: event)
        let callID = event.callID ?? keys.first ?? "event-\(event.cursor)"
        let name = event.tool ?? "tool"
        if let index = toolIndex[callID] ?? keys.compactMap({ stableIndex[$0] }).first {
            updateTool(at: index) { tool in
                PuckToolActivity(
                    callID: callID,
                    name: tool.name == "tool" ? name : tool.name,
                    arguments: event.arguments ?? tool.arguments,
                    output: tool.output,
                    state: tool.state
                )
            }
            if drafts[index].toolCallID == nil {
                drafts[index].toolCallID = callID
            }
            registerStableKeys(keys, at: index)
            toolIndex[callID] = index
            return
        }
        let index = appendDraft(Draft(
            id: "tool:\(callID)",
            role: .tool,
            content: .tool(PuckToolActivity(
                callID: callID,
                name: name,
                arguments: event.arguments,
                state: .running
            )),
            turnID: event.turnID,
            firstCursor: event.cursor,
            lastCursor: event.cursor,
            truncated: event.truncated,
            stableKeys: keys,
            toolCallID: callID,
            fromHistory: false,
            matchedLive: false,
            isStream: false
        ))
        registerStableKeys(keys, at: index)
        toolIndex[callID] = index
    }

    private mutating func appendToolResult(_ event: PuckSessionEvent) {
        let keys = stableKeys(for: event)
        let callID = event.callID ?? keys.first ?? "event-\(event.cursor)"
        let state: PuckToolState = event.truncated ? .truncated : event.success == false ? .failed : .succeeded
        let name = event.tool ?? "tool"
        if let index = toolIndex[callID] ?? keys.compactMap({ stableIndex[$0] }).first {
            updateTool(at: index) { tool in
                let output = tool.output.isEmpty ? (event.output ?? "") : tool.output
                return PuckToolActivity(
                    callID: callID,
                    name: tool.name == "tool" ? name : tool.name,
                    arguments: tool.arguments,
                    output: output,
                    state: state
                )
            }
            drafts[index].lastCursor = event.cursor
            drafts[index].truncated = event.truncated || drafts[index].truncated
            if drafts[index].toolCallID == nil {
                drafts[index].toolCallID = callID
            }
            registerStableKeys(keys, at: index)
            toolIndex[callID] = index
            return
        }
        let index = appendDraft(Draft(
            id: "tool:\(callID)",
            role: .tool,
            content: .tool(PuckToolActivity(
                callID: callID,
                name: name,
                output: event.output ?? "",
                state: state
            )),
            turnID: event.turnID,
            firstCursor: event.cursor,
            lastCursor: event.cursor,
            truncated: event.truncated,
            stableKeys: keys,
            toolCallID: callID,
            fromHistory: false,
            matchedLive: false,
            isStream: false
        ))
        registerStableKeys(keys, at: index)
        toolIndex[callID] = index
    }

    private mutating func appendHostedCall(_ event: PuckSessionEvent) {
        let keys = stableKeys(for: event)
        if keys.compactMap({ stableIndex[$0] }).first != nil { return }
        let callID = event.callID ?? "hosted-\(event.cursor)"
        let index = appendDraft(Draft(
            id: "tool:\(callID)",
            role: .tool,
            content: .tool(PuckToolActivity(
                callID: callID,
                name: event.route ?? "hosted_call",
                output: event.query ?? "Hosted call",
                state: .succeeded
            )),
            turnID: event.turnID,
            firstCursor: event.cursor,
            lastCursor: event.cursor,
            truncated: event.truncated,
            stableKeys: keys,
            toolCallID: callID,
            fromHistory: false,
            matchedLive: false,
            isStream: false
        ))
        registerStableKeys(keys, at: index)
        toolIndex[callID] = index
    }

    private mutating func appendUnknown(_ event: PuckSessionEvent) {
        var fields = ["event=\(event.kind)", "cursor=\(event.cursor)"]
        if let callID = event.callID { fields.append("call_id=\(callID)") }
        if let tool = event.tool { fields.append("tool=\(tool)") }
        fields.append(contentsOf: event.metadata.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })
        let fallback = event.text ?? event.message ?? event.output ?? "Unknown event"
        _ = appendDraft(Draft(
            id: "event:\(event.cursor)",
            role: .unknown,
            content: .unknown(kind: event.kind, detail: ([fallback] + fields).joined(separator: "\n")),
            turnID: event.turnID,
            firstCursor: event.cursor,
            lastCursor: event.cursor,
            truncated: event.truncated,
            stableKeys: stableKeys(for: event),
            toolCallID: nil,
            fromHistory: false,
            matchedLive: false,
            isStream: false
        ))
    }

    private mutating func fallbackHistoryIndex(role: PuckTimelineRole, text: String, turnID: String?) -> Int? {
        drafts.indices.reversed().first { index in
            let draft = drafts[index]
            guard draft.fromHistory, !draft.matchedLive, draft.role == role, draft.text == text else { return false }
            if let turnID, let historyTurn = draft.turnID, turnID != historyTurn { return false }
            return true
        }
    }

    private mutating func updateTool(at index: Int, update: (PuckToolActivity) -> PuckToolActivity) {
        guard drafts.indices.contains(index), case .tool(let tool) = drafts[index].content else { return }
        drafts[index].content = .tool(update(tool))
    }

    private func stableKeys(for event: PuckSessionEvent) -> [String] {
        var keys: [String] = []
        for key in [event.itemID, event.historyRef].compactMap({ $0 }) where !keys.contains(key) {
            keys.append(key)
        }
        return keys
    }

    private mutating func registerStableKeys(_ keys: [String], at index: Int) {
        guard drafts.indices.contains(index) else { return }
        for key in keys where !drafts[index].stableKeys.contains(key) {
            drafts[index].stableKeys.append(key)
            stableIndex[key] = index
        }
    }

    private mutating func registerTools(at index: Int) {
        guard drafts.indices.contains(index), let callID = drafts[index].toolCallID else { return }
        toolIndex[callID] = index
    }

    private mutating func appendDraft(_ draft: Draft) -> Int {
        let index = drafts.count
        drafts.append(draft)
        for key in draft.stableKeys { stableIndex[key] = index }
        if let callID = draft.toolCallID { toolIndex[callID] = index }
        return index
    }

    private mutating func removeDraft(at index: Int) {
        guard drafts.indices.contains(index) else { return }
        drafts.remove(at: index)
        stableIndex.removeAll(keepingCapacity: true)
        toolIndex.removeAll(keepingCapacity: true)
        for (position, draft) in drafts.enumerated() {
            for key in draft.stableKeys { stableIndex[key] = position }
            if let callID = draft.toolCallID { toolIndex[callID] = position }
        }
        if let current = streamIndex {
            streamIndex = current == index ? nil : current > index ? current - 1 : current
        }
    }

    private mutating func enforceLimits() {
        while drafts.count > limits.maxItems || drafts.reduce(0, { $0 + $1.retainedByteCount }) > limits.maxBytes {
            guard !drafts.isEmpty else { break }
            removeDraft(at: 0)
        }
    }

    private func errorRole(for message: String) -> PuckTimelineRole {
        let lower = message.lowercased()
        return lower.contains("cancel") || lower.contains("interrupt") ? .interruption : .error
    }
}
