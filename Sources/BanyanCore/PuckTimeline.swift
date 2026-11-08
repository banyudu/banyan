import Foundation
import PuckSwift

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
        var images: [String] = []
        /// Live `tool_output_delta` text, replaced by the finished result.
        var outputStreamed = false
        var isReasoningStream = false

        var text: String {
            switch content {
            case .user(let text), .assistant(let text), .reasoning(let text), .error(let text), .interruption(let text):
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
            bytes += images.reduce(0) { $0 + $1.utf8.count }
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
                truncated: truncated,
                images: images,
                isStreaming: isStream || isReasoningStream || outputStreamed
            )
        }
    }

    private struct NoticeDraft {
        var id: String
        var role: PuckTimelineRole
        var text: String
        var turnID: String?
        var callID: String?
        var firstCursor: UInt64?
        var lastCursor: UInt64?
        var truncated: Bool
        var stableKeys: [String]

        var notice: PuckTimelineNotice {
            PuckTimelineNotice(
                id: id,
                role: role,
                text: text,
                turnID: turnID,
                callID: callID,
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
        "model_retry",
    ]
    /// The newest `tool_output_delta` text kept per command, so a chatty
    /// command cannot crowd the transcript out of its byte budget.
    static let maxStreamedOutputBytes = 64 * 1024

    private let limits: PuckTimelineLimits
    private var drafts: [Draft] = []
    private var notices: [NoticeDraft] = []
    private var stableIndex: [String: Int] = [:]
    private var noticeIndex: [String: Int] = [:]
    private var toolIndex: [String: Int] = [:]
    private var seenCursors: Set<UInt64> = []
    private var streamIndex: Int?
    private var reasoningStreams: [String: Int] = [:]
    private var usage: PuckUsage?
    private var activity: String?

    init(limits: PuckTimelineLimits) {
        self.limits = limits
    }

    mutating func append(history: [PuckHistoryItem]) {
        var index = 0
        while index < history.count {
            let item = history[index]
            var consumed = 1
            switch item.kind.lowercased() {
            case "tool_call":
                append(historyToolCall: item)
            case "tool_result":
                append(historyToolResult: item)
            case "tool", "tool_start", "command", "file_change":
                if item.toolName != nil || item.callID != nil || item.arguments != nil {
                    append(historyToolResult: item, name: item.toolName, arguments: item.arguments)
                } else if let name = Self.historyToolCallName(item) {
                    let next = index + 1 < history.count ? history[index + 1] : nil
                    let output = next.flatMap {
                        Self.isHistoryToolItem($0) && Self.historyToolCallName($0) == nil ? $0 : nil
                    }
                    append(legacyHistoryToolCall: item, name: name, output: output)
                    consumed = output == nil ? 1 : 2
                } else {
                    append(historyItem: item)
                }
            default:
                append(historyItem: item)
            }
            index += consumed
        }
        enforceLimits()
    }

    mutating func append(events: [PuckSessionEvent]) {
        for event in events { append(event: event) }
        enforceLimits()
    }

    mutating func finish() -> PuckTimeline {
        PuckTimeline(
            items: drafts.map(\.timelineItem),
            notices: notices.map(\.notice),
            usage: usage,
            activity: activity
        )
    }

    /// Protocol 2.1 exposed a native call as a `tool` row whose text was only
    /// the tool name, followed by its output as another `tool` row. Older
    /// daemons still return that shape, so recognize the known wrapper names
    /// and pair them with the following row.
    private static func historyToolCallName(_ item: PuckHistoryItem) -> String? {
        guard isHistoryToolItem(item) else { return nil }
        let text = item.text
        guard text.count <= 64,
              !text.isEmpty,
              text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            return nil
        }
        let normalized = text.lowercased()
        let isKnownName = historyToolNames.contains(normalized)
            || historyToolNamePrefixes.contains { normalized.hasPrefix($0) }
        guard isKnownName else { return nil }
        return text
    }

    private static func isHistoryToolItem(_ item: PuckHistoryItem) -> Bool {
        switch item.kind.lowercased() {
        case "tool", "tool_call", "tool_result", "tool_start", "command", "file_change":
            return true
        default:
            return false
        }
    }

    private static let historyToolNames: Set<String> = [
        "agent", "apply_patch", "ask", "bash", "create_goal", "edit", "exec_command",
        "fetch", "get_goal", "glob", "grep", "list_dir", "list_directory", "list_files",
        "ls", "patch", "plan", "question", "read", "read_file", "request_user_input",
        "run_command", "search", "shell", "spawn_agent", "terminal", "tool", "update_goal",
        "update_plan", "view_image", "web_search", "webfetch", "write", "write_file",
        "write_stdin",
    ]

    private static let historyToolNamePrefixes = [
        "agents.", "epics.", "jobs.", "mcp__", "sessions.", "tasks.",
    ]

    private mutating func append(historyToolCall item: PuckHistoryItem) {
        let callID = item.callID ?? item.id
        let name = item.toolName ?? item.text
        if let index = toolIndex[callID] {
            updateTool(at: index) { tool in
                PuckToolActivity(
                    callID: tool.callID,
                    name: name.isEmpty ? tool.name : name,
                    arguments: item.arguments ?? tool.arguments,
                    output: tool.output,
                    state: item.truncated ? .truncated : tool.state
                )
            }
            registerHistoryToolItem(item, callID: callID, at: index)
            return
        }
        let index = appendDraft(Draft(
            id: "tool:\(item.id)",
            role: .tool,
            content: .tool(PuckToolActivity(
                callID: callID,
                name: name.isEmpty ? "tool" : name,
                arguments: item.arguments,
                output: "",
                state: item.truncated ? .truncated : .succeeded
            )),
            turnID: item.turnID,
            firstCursor: nil,
            lastCursor: nil,
            truncated: item.truncated,
            stableKeys: [item.id],
            toolCallID: callID,
            fromHistory: true,
            matchedLive: false,
            isStream: false
        ))
        toolIndex[callID] = index
    }

    private mutating func append(
        historyToolResult item: PuckHistoryItem,
        name: String? = nil,
        arguments: String? = nil
    ) {
        let callID = item.callID ?? item.id
        if let index = toolIndex[callID] {
            updateTool(at: index) { tool in
                PuckToolActivity(
                    callID: tool.callID,
                    name: name ?? tool.name,
                    arguments: arguments ?? tool.arguments,
                    output: tool.output.isEmpty ? item.text : tool.output,
                    state: item.truncated || tool.state == .truncated ? .truncated : .succeeded
                )
            }
            registerHistoryToolItem(item, callID: callID, at: index)
            return
        }
        let index = appendDraft(Draft(
            id: "tool:\(item.id)",
            role: .tool,
            content: .tool(PuckToolActivity(
                callID: callID,
                name: name ?? item.toolName ?? "tool",
                arguments: arguments ?? item.arguments,
                output: item.text,
                state: item.truncated ? .truncated : .succeeded
            )),
            turnID: item.turnID,
            firstCursor: nil,
            lastCursor: nil,
            truncated: item.truncated,
            stableKeys: [item.id],
            toolCallID: callID,
            fromHistory: true,
            matchedLive: false,
            isStream: false
        ))
        toolIndex[callID] = index
    }

    private mutating func registerHistoryToolItem(
        _ item: PuckHistoryItem,
        callID: String,
        at index: Int
    ) {
        registerStableKeys([item.id], at: index)
        drafts[index].truncated = drafts[index].truncated || item.truncated
        toolIndex[callID] = index
    }

    private mutating func append(
        legacyHistoryToolCall call: PuckHistoryItem,
        name: String,
        output: PuckHistoryItem?
    ) {
        guard stableIndex[call.id] == nil else { return }
        var stableKeys = [call.id]
        if let output, !stableKeys.contains(output.id) {
            stableKeys.append(output.id)
        }
        let index = appendDraft(Draft(
            id: "tool:\(call.id)",
            role: .tool,
            content: .tool(PuckToolActivity(
                callID: call.id,
                name: name,
                output: output?.text ?? "",
                state: .succeeded
            )),
            turnID: call.turnID ?? output?.turnID,
            firstCursor: nil,
            lastCursor: nil,
            truncated: call.truncated || output?.truncated == true,
            stableKeys: stableKeys,
            toolCallID: call.id,
            fromHistory: true,
            matchedLive: false,
            isStream: false
        ))
        toolIndex[call.id] = index
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
        case "reasoning":
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            role = .reasoning
            content = .reasoning(text)
        case "tool", "tool_result", "tool_start", "command", "file_change":
            role = .tool
            content = .tool(PuckToolActivity(
                callID: item.id,
                name: "tool",
                output: text,
                state: .succeeded
            ))
        case "error", "turn_error", "persistence_error", "audit_error":
            appendNotice(
                role: errorRole(for: text),
                text: text,
                turnID: item.turnID,
                callID: nil,
                cursor: nil,
                truncated: item.truncated,
                stableKeys: [item.id],
                matchFallback: false
            )
            return
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
            isStream: false,
            images: role == .user ? item.images ?? [] : []
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
            activity = nil
        case "turn_done":
            streamIndex = nil
            activity = nil
            finishStreams()
        case "model_retry":
            activity = event.message.map { "Reconnecting: \($0)" } ?? "Reconnecting…"
        case "reasoning_delta":
            appendReasoning(event, delta: true)
        case "reasoning":
            appendReasoning(event, delta: false)
        case "tool_output_delta":
            appendToolOutputDelta(event)
        case "usage":
            usage = event.usage ?? usage
        case "text_delta":
            appendTextDelta(event)
        case "assistant_message":
            appendMessage(role: .assistant, event: event, text: event.text ?? "")
        case "user_message":
            appendMessage(role: .user, event: event, text: event.text ?? "", images: event.images)
        case "tool_start":
            appendToolStart(event)
        case "approval_pending":
            appendToolApproval(event)
        case "tool_result":
            appendToolResult(event)
        case "hosted_call":
            appendHostedCall(event)
        case "turn_error", "persistence_error", "audit_error":
            activity = nil
            finishStreams()
            let text = event.message ?? event.text ?? "Turn failed"
            appendNotice(
                role: errorRole(for: text),
                text: text,
                turnID: event.turnID,
                callID: event.callID,
                cursor: event.cursor,
                truncated: event.truncated,
                stableKeys: stableKeys(for: event)
            )
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
        text: String,
        images: [String] = []
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
            isStream: false,
            images: images
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

    private mutating func appendToolApproval(_ event: PuckSessionEvent) {
        guard let arguments = event.arguments, !arguments.isEmpty else { return }
        let keys = stableKeys(for: event)
        let callID = event.callID ?? keys.first
        guard let callID,
              let index = toolIndex[callID] ?? keys.compactMap({ stableIndex[$0] }).first else {
            return
        }
        updateTool(at: index) { tool in
            PuckToolActivity(
                callID: callID,
                name: tool.name == "tool" ? (event.tool ?? tool.name) : tool.name,
                arguments: arguments,
                output: tool.output,
                state: tool.state
            )
        }
        registerStableKeys(keys, at: index)
        toolIndex[callID] = index
    }

    private mutating func appendToolResult(_ event: PuckSessionEvent) {
        let keys = stableKeys(for: event)
        let callID = event.callID ?? keys.first ?? "event-\(event.cursor)"
        let state: PuckToolState = event.truncated ? .truncated : event.success == false ? .failed : .succeeded
        let name = event.tool ?? "tool"
        if let index = toolIndex[callID] ?? keys.compactMap({ stableIndex[$0] }).first {
            let streamed = drafts[index].outputStreamed
            drafts[index].outputStreamed = false
            updateTool(at: index) { tool in
                let finished = event.output ?? ""
                let output = tool.output.isEmpty || (streamed && !finished.isEmpty) ? finished : tool.output
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

    /// A reasoning summary streams as `reasoning_delta` text and finishes as
    /// one journaled `reasoning` event with the same item ID.
    private mutating func appendReasoning(_ event: PuckSessionEvent, delta: Bool) {
        guard let text = event.text, !text.isEmpty else { return }
        let keys = stableKeys(for: event)
        let streamKey = event.itemID ?? "reasoning"
        if let index = reasoningStreams[streamKey], drafts.indices.contains(index),
           drafts[index].isReasoningStream, case .reasoning(let existing) = drafts[index].content {
            drafts[index].content = .reasoning(delta ? existing + text : text)
            drafts[index].lastCursor = event.cursor
            if !delta {
                drafts[index].isReasoningStream = false
                reasoningStreams[streamKey] = nil
                registerStableKeys(keys, at: index)
            }
            activity = PuckTimelineContent.reasoningHeading(drafts[index].text) ?? activity
            return
        }
        if let index = keys.compactMap({ stableIndex[$0] }).first {
            if !delta { drafts[index].matchedLive = true }
            return
        }
        if !delta, keys.isEmpty,
           let index = fallbackHistoryIndex(role: .reasoning, text: text, turnID: event.turnID) {
            drafts[index].matchedLive = true
            return
        }
        let index = appendDraft(Draft(
            id: delta ? "reasoning:\(streamKey)" : keys.first.map { "item:\($0)" } ?? "event:\(event.cursor)",
            role: .reasoning,
            content: .reasoning(text),
            turnID: event.turnID,
            firstCursor: event.cursor,
            lastCursor: event.cursor,
            truncated: event.truncated,
            stableKeys: delta ? [] : keys,
            toolCallID: nil,
            fromHistory: false,
            matchedLive: false,
            isStream: false,
            isReasoningStream: delta
        ))
        if delta { reasoningStreams[streamKey] = index }
        activity = PuckTimelineContent.reasoningHeading(text) ?? activity
    }

    /// Live command output. Only the newest text is kept; the finished
    /// `tool_result` replaces it.
    private mutating func appendToolOutputDelta(_ event: PuckSessionEvent) {
        guard let delta = event.output ?? event.text, !delta.isEmpty,
              let callID = event.callID, let index = toolIndex[callID], drafts.indices.contains(index),
              case .tool(let tool) = drafts[index].content, tool.state == .running else { return }
        var output = (drafts[index].outputStreamed ? tool.output : "") + delta
        let excess = output.utf8.count - Self.maxStreamedOutputBytes
        if excess > 0 {
            let cut = output.utf8.index(output.utf8.startIndex, offsetBy: excess)
            var tail = Substring(output[cut...])
            if let newline = tail.firstIndex(of: "\n") { tail = tail[tail.index(after: newline)...] }
            output = String(tail)
        }
        drafts[index].outputStreamed = true
        drafts[index].content = .tool(PuckToolActivity(
            callID: tool.callID,
            name: tool.name,
            arguments: tool.arguments,
            output: output,
            state: tool.state
        ))
    }

    /// A finished or failed turn ends any summary still marked as streaming.
    private mutating func finishStreams() {
        for index in reasoningStreams.values where drafts.indices.contains(index) {
            drafts[index].isReasoningStream = false
        }
        reasoningStreams = [:]
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

    private mutating func appendNotice(
        role: PuckTimelineRole,
        text: String,
        turnID: String?,
        callID: String?,
        cursor: UInt64?,
        truncated: Bool,
        stableKeys: [String],
        matchFallback: Bool = true
    ) {
        let keyedIndex = stableKeys.compactMap({ noticeIndex[$0] }).first
        let fallbackIndex = matchFallback
            ? fallbackNoticeIndex(role: role, text: text, turnID: turnID, callID: callID)
            : nil
        if let index = keyedIndex ?? fallbackIndex {
            if let cursor {
                notices[index].firstCursor = notices[index].firstCursor ?? cursor
                notices[index].lastCursor = max(notices[index].lastCursor ?? cursor, cursor)
            }
            notices[index].truncated = notices[index].truncated || truncated
            for key in stableKeys where !notices[index].stableKeys.contains(key) {
                notices[index].stableKeys.append(key)
                noticeIndex[key] = index
            }
            return
        }

        let id = stableKeys.first.map { "notice:\($0)" }
            ?? "notice:\(turnID ?? "session"):\(callID ?? "call"):\(role.rawValue):\(text)"
        let index = notices.count
        notices.append(NoticeDraft(
            id: id,
            role: role,
            text: text,
            turnID: turnID,
            callID: callID,
            firstCursor: cursor,
            lastCursor: cursor,
            truncated: truncated,
            stableKeys: stableKeys
        ))
        for key in stableKeys { noticeIndex[key] = index }
    }

    private func fallbackNoticeIndex(
        role: PuckTimelineRole,
        text: String,
        turnID: String?,
        callID: String?
    ) -> Int? {
        notices.indices.reversed().first { index in
            let notice = notices[index]
            guard notice.role == role, notice.text == text else { return false }
            if let turnID, let existingTurn = notice.turnID, turnID != existingTurn { return false }
            if callID != notice.callID { return false }
            return true
        }
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
        reasoningStreams = reasoningStreams.compactMapValues { current in
            current == index ? nil : current > index ? current - 1 : current
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
