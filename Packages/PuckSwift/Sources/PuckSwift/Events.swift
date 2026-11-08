import Foundation

public struct PuckTokenUsage: Equatable, Sendable {
    public let reportedRequests: UInt64
    public let unreportedRequests: UInt64
    public let inputTokens: UInt64
    public let outputTokens: UInt64
    public let cachedInputTokens: UInt64
    public let cacheUnreportedRequests: UInt64

    public static let zero = PuckTokenUsage()

    public init(
        reportedRequests: UInt64 = 0,
        unreportedRequests: UInt64 = 0,
        inputTokens: UInt64 = 0,
        outputTokens: UInt64 = 0,
        cachedInputTokens: UInt64 = 0,
        cacheUnreportedRequests: UInt64 = 0
    ) {
        self.reportedRequests = reportedRequests
        self.unreportedRequests = unreportedRequests
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheUnreportedRequests = cacheUnreportedRequests
    }

    public init?(_ value: Any?) {
        guard let object = value as? [String: Any] else { return nil }
        reportedRequests = Self.integer(object["reported_requests"])
        unreportedRequests = Self.integer(object["unreported_requests"])
        inputTokens = Self.integer(object["input_tokens"] ?? object["inputTokens"])
        outputTokens = Self.integer(object["output_tokens"] ?? object["outputTokens"])
        cachedInputTokens = Self.integer(object["cached_input_tokens"] ?? object["cachedInputTokens"])
        cacheUnreportedRequests = Self.integer(object["cache_unreported_requests"])
    }

    private static func integer(_ value: Any?) -> UInt64 {
        (value as? NSNumber)?.uint64Value ?? 0
    }
}

public struct PuckUsage: Equatable, Sendable {
    public let total: PuckTokenUsage
    public let last: PuckTokenUsage?

    public init(total: PuckTokenUsage, last: PuckTokenUsage? = nil) {
        self.total = total
        self.last = last
    }

    public init?(_ value: Any?) {
        guard let object = value as? [String: Any],
              let total = PuckTokenUsage(object["usage"] ?? object["total"]) else { return nil }
        self.total = total
        last = PuckTokenUsage(object["last"])
    }
}

/// One journaled or transient session event. Transient events, such as
/// `text_delta`, `reasoning_delta` and `tool_output_delta`, are live progress
/// that the finished item or paged history supersedes.
public struct PuckSessionEvent: Sendable {
    public let cursor: UInt64
    public let kind: String
    public let text: String?
    public let message: String?
    public let tool: String?
    public let callID: String?
    public let arguments: String?
    public let output: String?
    public let query: String?
    public let route: String?
    public let notify: Bool?
    public let transient: Bool
    public let itemID: String?
    public let historyRef: String?
    public let turnID: String?
    public let success: Bool?
    public let truncated: Bool
    public let usage: PuckUsage?
    /// Daemon-owned copies of the images attached to a `user_message`.
    public let images: [String]
    /// Scalar fields not modeled above, retained so a newer daemon event kind
    /// remains inspectable to older clients.
    public let metadata: [String: String]

    public init(
        cursor: UInt64,
        kind: String,
        text: String? = nil,
        message: String? = nil,
        tool: String? = nil,
        callID: String? = nil,
        arguments: String? = nil,
        output: String? = nil,
        query: String? = nil,
        route: String? = nil,
        notify: Bool? = nil,
        transient: Bool = false,
        itemID: String? = nil,
        historyRef: String? = nil,
        turnID: String? = nil,
        success: Bool? = nil,
        truncated: Bool = false,
        usage: PuckUsage? = nil,
        images: [String] = [],
        metadata: [String: String] = [:]
    ) {
        self.cursor = cursor
        self.kind = kind
        self.text = text
        self.message = message
        self.tool = tool
        self.callID = callID
        self.arguments = arguments
        self.output = output
        self.query = query
        self.route = route
        self.notify = notify
        self.transient = transient
        self.itemID = itemID
        self.historyRef = historyRef
        self.turnID = turnID
        self.success = success
        self.truncated = truncated
        self.usage = usage
        self.images = images
        self.metadata = metadata
    }

    public init(_ object: [String: Any]) throws {
        guard let data = object["data"] as? [String: Any],
              let kind = data["event"] as? String else {
            throw PuckDaemonError.invalidResponse("event")
        }
        guard let cursor = (object["cursor"] as? NSNumber)?.uint64Value ?? (kind == "lagged" ? 0 : nil) else {
            throw PuckDaemonError.invalidResponse("event cursor")
        }
        self.cursor = cursor
        self.kind = kind
        text = data["text"] as? String
        message = data["message"] as? String
        tool = data["tool"] as? String
        callID = data["call_id"] as? String
        arguments = data["arguments"] as? String
        output = data["output"] as? String
        query = data["query"] as? String
        route = data["route"] as? String
        notify = data["notify"] as? Bool
        transient = data["transient"] as? Bool ?? false
        itemID = data["item_id"] as? String
        historyRef = data["history_ref"] as? String
        turnID = data["turn_id"] as? String
        success = data["success"] as? Bool
        truncated = data["truncated"] as? Bool ?? false
        usage = PuckUsage(data["usage"])
        images = (data["images"] as? [Any])?.compactMap { $0 as? String } ?? []
        let modeled: Set<String> = [
            "event", "text", "message", "tool", "call_id", "arguments", "output", "query",
            "route", "notify", "transient", "item_id", "history_ref", "turn_id", "success",
            "truncated", "usage", "images",
        ]
        metadata = data.reduce(into: [:]) { result, entry in
            guard !modeled.contains(entry.key), let value = Self.scalar(entry.value) else { return }
            result[entry.key] = value
        }
    }

    public var retainedByteCount: Int {
        let strings = [text, message, tool, callID, arguments, output, query, route, itemID, historyRef, turnID]
        return strings.reduce(512) { total, value in
            guard let value else { return total }
            return total + max(value.utf8.count, value.utf16.count * 2)
        } + images.reduce(0) { $0 + $1.utf8.count }
            + metadata.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
    }

    public var displayText: String? {
        switch kind {
        case "turn_started": return "Running…"
        case "text_delta", "user_message", "assistant_message": return text
        case "tool_start": return "Running \(tool ?? "tool")"
        case "tool_result": return "\(tool ?? "Tool"): \(output ?? "finished")"
        case "hosted_call": return query.map { "Hosted call: \($0)" } ?? "Hosted call"
        case "turn_done": return text ?? "Turn finished"
        case "turn_error", "persistence_error", "audit_error": return message ?? "Turn failed"
        case "approval_pending": return "Approval needed for \(tool ?? "tool"): \(arguments ?? "")"
        case "approval_decided": return "Approval decided"
        case "blocked_on_question": return "Question needs an answer"
        case "question_answered": return "Question answered"
        case "hibernated": return "Session hibernated"
        default: return nil
        }
    }

    private static func scalar(_ value: Any) -> String? {
        if value is NSNull { return nil }
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
