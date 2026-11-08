import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A puck session is durable daemon state. Every frontend uses this same local
/// JSON-RPC protocol; none needs to start or scrape an agent process.
public struct PuckSessionSummary: Equatable, Sendable {
    public let id: String
    public let engine: String
    public let provider: String
    public let account: String
    public let workspace: String
    public let cwd: String
    public let model: String
    public let position: String
    public let parentSession: String?
    public let subagentName: String?
    public let agentClass: String
    public let presentation: PuckSessionPresentation?
    /// Items in the saved conversation. Zero means no turn has run yet.
    public let historyItems: Int
    public let pendingApproval: PuckPendingApproval?
    public let pendingQuestion: PuckPendingQuestion?

    public init(
        id: String,
        engine: String = "native",
        provider: String,
        account: String,
        workspace: String,
        cwd: String,
        model: String,
        position: String,
        parentSession: String? = nil,
        subagentName: String? = nil,
        historyItems: Int = 0,
        pendingApproval: PuckPendingApproval? = nil,
        pendingQuestion: PuckPendingQuestion? = nil,
        agentClass: String = "worker",
        presentation: PuckSessionPresentation? = nil
    ) {
        self.id = id
        self.engine = engine
        self.provider = provider
        self.account = account
        self.workspace = workspace
        self.cwd = cwd
        self.model = model
        self.position = position
        self.parentSession = parentSession
        self.subagentName = subagentName
        self.agentClass = agentClass
        self.presentation = presentation
        self.historyItems = historyItems
        self.pendingApproval = pendingApproval
        self.pendingQuestion = pendingQuestion
    }

    public init(_ object: [String: Any]) throws {
        id = try Self.string("id", in: object)
        engine = object["engine"] as? String ?? "native"
        provider = try Self.string("provider", in: object)
        account = try Self.string("account", in: object)
        workspace = try Self.string("workspace", in: object)
        cwd = try Self.string("cwd", in: object)
        model = try Self.string("model", in: object)
        position = try Self.string("position", in: object)
        parentSession = object["parent_session"] as? String
        subagentName = object["subagent_name"] as? String
        agentClass = object["class"] as? String ?? "worker"
        presentation = try (object["presentation"] as? [String: Any]).map(PuckSessionPresentation.init)
        historyItems = (object["history_items"] as? NSNumber)?.intValue ?? 0
        pendingApproval = try (object["pending_approval"] as? [String: Any]).map(PuckPendingApproval.init)
        pendingQuestion = try (object["pending_question"] as? [String: Any]).map(PuckPendingQuestion.init)
    }

    private static func string(_ key: String, in object: [String: Any]) throws -> String {
        guard let value = object[key] as? String else { throw PuckDaemonError.invalidResponse(key) }
        return value
    }
}

public struct PuckPendingApproval: Equatable, Sendable {
    public let callID: String
    public let tool: String
    public let arguments: String
    public let expiresAtMS: UInt64

    public init(callID: String, tool: String, arguments: String, expiresAtMS: UInt64) {
        self.callID = callID
        self.tool = tool
        self.arguments = arguments
        self.expiresAtMS = expiresAtMS
    }

    public init(_ object: [String: Any]) throws {
        guard let callID = object["call_id"] as? String,
              let tool = object["tool"] as? String,
              let arguments = object["arguments"] as? String,
              let expiresAtMS = (object["expires_at_ms"] as? NSNumber)?.uint64Value else {
            throw PuckDaemonError.invalidResponse("pending_approval")
        }
        self.callID = callID
        self.tool = tool
        self.arguments = arguments
        self.expiresAtMS = expiresAtMS
    }
}

public struct PuckQuestionChoice: Equatable, Sendable {
    public let label: String
    public let description: String

    public init(_ object: [String: Any]) throws {
        guard let label = object["label"] as? String,
              let description = object["description"] as? String else {
            throw PuckDaemonError.invalidResponse("question option")
        }
        self.label = label
        self.description = description
    }
}

public struct PuckQuestion: Equatable, Sendable {
    public let header: String
    public let question: String
    public let options: [PuckQuestionChoice]
    public let multiple: Bool
    public let custom: Bool
    public let defaultAnswer: String?

    public init(_ object: [String: Any]) throws {
        guard let header = object["header"] as? String,
              let question = object["question"] as? String,
              let options = object["options"] as? [[String: Any]],
              let multiple = object["multiple"] as? Bool,
              let custom = object["custom"] as? Bool else {
            throw PuckDaemonError.invalidResponse("question")
        }
        self.header = header
        self.question = question
        self.options = try options.map(PuckQuestionChoice.init)
        self.multiple = multiple
        self.custom = custom
        defaultAnswer = object["default"] as? String
    }
}

public struct PuckPendingQuestion: Equatable, Sendable {
    public let callID: String
    public let questions: [PuckQuestion]
    public let expiresAtMS: UInt64

    public init(_ object: [String: Any]) throws {
        guard let callID = object["call_id"] as? String,
              let questions = object["questions"] as? [[String: Any]],
              let expiresAtMS = (object["expires_at_ms"] as? NSNumber)?.uint64Value else {
            throw PuckDaemonError.invalidResponse("pending_question")
        }
        self.callID = callID
        self.questions = try questions.map(PuckQuestion.init)
        self.expiresAtMS = expiresAtMS
    }
}

public struct PuckQuestionSelection: Equatable, Sendable {
    public let labels: [String]
    public let text: String?

    public init(labels: [String] = [], text: String? = nil) {
        self.labels = labels
        self.text = text
    }

    var wireValue: [String: Any] {
        ["labels": labels, "text": text as Any? ?? NSNull()]
    }

    public static func decodeJSON(_ source: String) throws -> [Self] {
        guard let data = source.data(using: .utf8),
              let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw PuckDaemonError.rejected("--selections must be a JSON array")
        }
        return try entries.map { entry in
            guard let labels = entry["labels"] as? [String],
                  entry["text"] == nil || entry["text"] is NSNull || entry["text"] is String else {
                throw PuckDaemonError.rejected("each selection needs labels and optional text")
            }
            return Self(labels: labels, text: entry["text"] as? String)
        }
    }

    /// Terminal clients accept option numbers, comma-separated for a
    /// multi-choice question, or `text:...` when free text is offered.
    public static func parse(_ input: String, for question: PuckQuestion) -> Self? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("text:") {
            let value = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
            return question.custom && !value.isEmpty ? Self(text: value) : nil
        }
        let parts = trimmed.split(separator: ",", omittingEmptySubsequences: false)
        guard !parts.isEmpty, question.multiple || parts.count == 1 else { return nil }
        var labels: [String] = []
        for part in parts {
            guard let number = Int(part.trimmingCharacters(in: .whitespacesAndNewlines)),
                  number >= 1, number <= question.options.count else { return nil }
            let label = question.options[number - 1].label
            guard !labels.contains(label) else { return nil }
            labels.append(label)
        }
        return labels.isEmpty ? nil : Self(labels: labels)
    }
}

public struct PuckRenderedEvent: Identifiable, Sendable {
    public let id: UInt64
    public let kind: String
    public var text: String
}

public enum PuckTranscript {
    /// The Responses stream arrives as short text chunks. Render adjacent
    /// chunks as one message and suppress the duplicate final `turn_done` text.
    public static func render(_ events: [PuckSessionEvent]) -> [PuckRenderedEvent] {
        var rendered: [PuckRenderedEvent] = []
        var streamedThisTurn = false
        for event in events {
            if event.kind == "turn_started" { streamedThisTurn = false }
            if event.kind == "text_delta", let text = event.text {
                streamedThisTurn = true
                if rendered.last?.kind == "text_delta" {
                    rendered[rendered.count - 1].text += text
                } else {
                    rendered.append(PuckRenderedEvent(id: event.cursor, kind: event.kind, text: text))
                }
                continue
            }
            if (event.kind == "turn_done" || event.kind == "assistant_message") && streamedThisTurn { continue }
            if event.kind == "assistant_message" { streamedThisTurn = true }
            if let text = event.displayText {
                rendered.append(PuckRenderedEvent(id: event.cursor, kind: event.kind, text: text))
            }
        }
        return rendered
    }
}

public struct PuckEventBatch: Sendable {
    public let cursor: UInt64
    public let events: [PuckSessionEvent]

    public init(_ object: [String: Any]) throws {
        guard let cursor = (object["cursor"] as? NSNumber)?.uint64Value,
              let rawEvents = object["events"] as? [[String: Any]] else {
            throw PuckDaemonError.invalidResponse("events")
        }
        self.cursor = cursor
        events = try rawEvents.map(PuckSessionEvent.init)
    }
}

public struct PuckAttachedSession: Sendable {
    public let summary: PuckSessionSummary
    public let batch: PuckEventBatch
    public let hasPagedHistory: Bool

    public init(_ object: [String: Any]) throws {
        guard let summary = object["summary"] as? [String: Any] else {
            throw PuckDaemonError.invalidResponse("summary")
        }
        self.summary = try PuckSessionSummary(summary)
        self.batch = try PuckEventBatch(object)
        self.hasPagedHistory = object["history_api"] as? Bool ?? false
    }
}

public enum PuckDaemonError: LocalizedError {
    case unavailable(String)
    /// Local admission refused before any request reached the daemon.
    case notSubmitted(String)
    case invalidResponse(String)
    case rejected(String)
    case server(PuckServerError)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let detail): return "puckd unavailable: \(detail)"
        case .notSubmitted(let detail): return detail
        case .invalidResponse(let field): return "Invalid puckd response: \(field)"
        case .rejected(let message): return message
        case .server(let error): return error.message
        }
    }
}

/// A single connection owns a read buffer. Use a separate connection for each
/// command while an attached connection waits for notifications.
public final class PuckDaemonConnection {
    private let descriptor: Int32
    private var pending = Data()
    private var queuedNotifications: [[String: Any]] = []
    private var notificationBytes = 0
    private let writeLock = NSLock()
    private var requestID = 0
    // The daemon normally caps replay pages at 512 KiB. One individual event
    // can exceed a page, so allow a larger single JSON-RPC response.
    private static let maxLineBytes = 4 * 1_048_576

    public init(socketPath: String) throws {
        let pathBytes = Array(socketPath.utf8)
        var address = sockaddr_un()
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        guard !pathBytes.isEmpty, pathBytes.count < pathCapacity else {
            throw PuckDaemonError.unavailable("invalid socket path")
        }
        #if canImport(Glibc)
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw PuckDaemonError.unavailable(String(cString: strerror(errno))) }
        #if canImport(Darwin)
        var noSignal: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        #endif
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.copyBytes(from: pathBytes)
            bytes[pathBytes.count] = 0
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let detail = String(cString: strerror(errno))
            _ = close(fd)
            throw PuckDaemonError.unavailable(detail)
        }
        descriptor = fd
    }

    deinit { _ = close(descriptor) }

    public func disconnect() { _ = shutdown(descriptor, Int32(SHUT_RDWR)) }

    public func request(_ method: String, params: [String: Any] = [:]) throws -> Any {
        var timeout = timeval(tv_sec: 15, tv_usec: 0)
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        defer { var off = timeval(tv_sec: 0, tv_usec: 0); _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &off, socklen_t(MemoryLayout<timeval>.size)) }
        let id = try sendRequest(method, params: params)
        while let message = try readMessage() {
            if Self.isNotification(message) {
                notificationBytes += (try? JSONSerialization.data(withJSONObject: message).count) ?? Self.maxLineBytes
                guard queuedNotifications.count < 32 && notificationBytes <= 1_048_576 else { throw PuckDaemonError.unavailable("Notification buffer overflow; reconnect") }
                queuedNotifications.append(message)
                continue
            }
            guard (message["id"] as? NSNumber)?.intValue == id else { continue }
            if let error = message["error"] as? [String: Any] {
                if let data = error["data"] as? [String: Any], let code = data["code"] as? String {
                    throw PuckDaemonError.server(PuckServerError(code: code, message: data["message"] as? String ?? "puckd rejected the request"))
                }
                throw PuckDaemonError.rejected(error["message"] as? String ?? "puckd rejected the request")
            }
            guard let result = message["result"] else { throw PuckDaemonError.invalidResponse("result") }
            return result
        }
        throw PuckDaemonError.unavailable("connection closed")
    }

    /// Writes without taking ownership of the reader. A watched connection has
    /// one reader; presence replies are consumed alongside its notifications.
    @discardableResult
    public func sendRequest(_ method: String, params: [String: Any] = [:]) throws -> Int {
        writeLock.lock()
        defer { writeLock.unlock() }
        requestID += 1
        let bytes = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": requestID, "method": method, "params": params
        ]) + Data([10])
        try bytes.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                #if canImport(Darwin)
                let count = write(descriptor, base.advanced(by: written), bytes.count - written)
                #else
                // A daemon restart can close the socket between connect and
                // write. Linux must suppress SIGPIPE per write, not per process.
                let count = send(descriptor, base.advanced(by: written),
                                 bytes.count - written, Int32(MSG_NOSIGNAL))
                #endif
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw PuckDaemonError.unavailable(String(cString: strerror(errno))) }
                written += count
            }
        }
        return requestID
    }

    /// Returns nil at EOF. A detached frontend closes this socket; daemon state
    /// and any running turn continue for other clients, including Slack.
    public func nextEvent() throws -> PuckSessionEvent? {
        while let message = try nextNotification() {
            guard message["method"] as? String == "session.event",
                  let params = message["params"] as? [String: Any] else { continue }
            return try PuckSessionEvent(params)
        }
        return nil
    }

    public func nextNotification() throws -> [String: Any]? {
        if !queuedNotifications.isEmpty {
            let message = queuedNotifications.removeFirst()
            notificationBytes -= (try? JSONSerialization.data(withJSONObject: message).count) ?? 0
            return message
        }
        while let message = try readMessage() {
            if let error = message["error"] as? [String: Any] {
                if let data = error["data"] as? [String: Any], let code = data["code"] as? String {
                    throw PuckDaemonError.server(PuckServerError(code: code, message: data["message"] as? String ?? "puckd rejected the request"))
                }
                throw PuckDaemonError.rejected(error["message"] as? String ?? "puckd rejected the request")
            }
            if Self.isNotification(message) { return message }
        }
        return nil
    }

    private static func isNotification(_ message: [String: Any]) -> Bool {
        guard let method = message["method"] as? String else { return false }
        return ["session.event", "task.event", "job.event"].contains(method)
    }

    private func readMessage() throws -> [String: Any]? {
        while true {
            if let newline = pending.firstIndex(of: 10) {
                let line = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                guard line.count <= Self.maxLineBytes else {
                    throw PuckDaemonError.invalidResponse("line too large")
                }
                guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw PuckDaemonError.invalidResponse("JSON object")
                }
                return object
            }
            guard pending.count < Self.maxLineBytes else { throw PuckDaemonError.invalidResponse("line too large") }
            var buffer = [UInt8](repeating: 0, count: 8192)
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw PuckDaemonError.unavailable(String(cString: strerror(errno))) }
            guard count > 0 else { return nil }
            pending.append(contentsOf: buffer.prefix(count))
        }
    }
}

/// What a frontend sees while following one session: the replayed transcript
/// and summary first, then live events, and a fresh summary whenever an event
/// changes what the session is waiting on.
public enum PuckSessionUpdate: Sendable {
    case attached(PuckSessionSummary, [PuckSessionEvent])
    case events([PuckSessionEvent])
    case history(PuckHistoryPage)
    case summary(PuckSessionSummary)
}

/// The daemon operations Banyan's frontends use. `PuckDaemonClient` talks to
/// the real socket; tests substitute an in-memory daemon.
public protocol PuckDaemonService: Sendable {
    func list() throws -> [PuckSessionSummary]
    func get(_ id: String) throws -> PuckSessionSummary
    func create(id: String, provider: String, account: String?, model: String?,
                workspace: String) throws -> PuckSessionSummary
    func turn(_ id: String, prompt: String) throws
    /// Starts a turn whose user message carries local image files. The daemon
    /// copies each image into its own store before the engine reads it.
    func turn(_ id: String, prompt: String, images: [String]) throws
    /// Stops the active turn without closing the durable session.
    func cancel(_ id: String) throws
    func decide(_ id: String, callID: String, decision: String) throws
    /// A denial may carry the user's reason for the engine to see.
    func decide(_ id: String, callID: String, decision: String, reason: String?) throws
    /// Summarizes the conversation in place to free context.
    func compact(_ id: String) throws
    func capabilities() throws -> PuckCapabilities
    func answer(_ id: String, callID: String, selections: [PuckQuestionSelection]) throws
    func plan(_ id: String) throws -> String?
    func reject(_ id: String, callID: String, reason: String) throws
    func history(_ id: String, cursor: String?, limit: Int) throws -> PuckHistoryPage
    func watch() -> any PuckDaemonObservation
    /// Replays the session, then follows it live until the stream is cancelled.
    /// Cancelling detaches only this client; a running turn continues.
    func follow(_ id: String) -> AsyncThrowingStream<PuckSessionUpdate, Error>
}

/// Fallbacks for in-memory daemons and older embedders. Image input refuses
/// rather than silently dropping attachments.
public extension PuckDaemonService {
    func turn(_ id: String, prompt: String, images: [String]) throws {
        guard images.isEmpty else { throw PuckDaemonError.rejected("This client does not support image input") }
        try turn(id, prompt: prompt)
    }
    func cancel(_ id: String) throws {
        throw PuckDaemonError.rejected("This client does not support turn cancellation")
    }
    func decide(_ id: String, callID: String, decision: String, reason: String?) throws {
        try decide(id, callID: callID, decision: decision)
    }
    func compact(_ id: String) throws {
        throw PuckDaemonError.rejected("This client does not support compaction")
    }
    func capabilities() throws -> PuckCapabilities {
        throw PuckDaemonError.rejected("This client does not report daemon capabilities")
    }
}

public struct PuckDaemonClient: Sendable {
    public let socketPath: String

    public init(environment: [String: String] = ProcessInfo.processInfo.environment,
                homeDirectory: String = NSHomeDirectory()) {
        let home = environment["PUCK_HOME"] ?? (homeDirectory as NSString).appendingPathComponent(".puck")
        socketPath = (home as NSString).appendingPathComponent("daemon/puck.sock")
    }

    public init(socketPath: String) { self.socketPath = socketPath }

    public func list() throws -> [PuckSessionSummary] {
        let value = try PuckDaemonConnection(socketPath: socketPath).request("session.list")
        guard let items = value as? [[String: Any]] else { throw PuckDaemonError.invalidResponse("list") }
        return try items.map(PuckSessionSummary.init)
    }

    public func get(_ id: String) throws -> PuckSessionSummary {
        let value = try PuckDaemonConnection(socketPath: socketPath).request("session.get", params: ["session": id])
        guard let object = value as? [String: Any] else { throw PuckDaemonError.invalidResponse("summary") }
        return try PuckSessionSummary(object)
    }

    public func create(id: String, provider: String, account: String? = nil,
                       model: String? = nil, workspace: String,
                       settings: [String: Any] = [:], engine: String? = nil) throws -> PuckSessionSummary {
        var params: [String: Any] = ["id": id, "provider": provider, "workspace": workspace,
                                     "cwd": workspace, "settings": settings]
        let selectedEngine = engine ?? (provider == "codex" ? "codex" : "native")
        guard ["codex", "native"].contains(selectedEngine) else {
            throw PuckDaemonError.rejected("engine must be codex or native")
        }
        params["engine"] = selectedEngine
        if let account { params["account"] = account }
        if let model { params["model"] = model }
        let connection = try PuckDaemonConnection(socketPath: socketPath)
        if selectedEngine == "codex" {
            let capabilities = try connection.request("daemon.capabilities") as? [String: Any]
            guard (capabilities?["engines"] as? [String])?.contains("codex") == true else {
                throw PuckDaemonError.rejected("puckd needs an update and restart before it can create Codex-engine sessions")
            }
        }
        let value = try connection.request("session.create", params: params)
        guard let object = value as? [String: Any] else { throw PuckDaemonError.invalidResponse("summary") }
        return try PuckSessionSummary(object)
    }

    public func turn(_ id: String, prompt: String) throws {
        try turn(id, prompt: prompt, images: [])
    }

    /// `images` are absolute paths. A daemon without the `turn_images`
    /// feature ignores unknown parameters, so callers must check capabilities
    /// before attaching images.
    public func turn(_ id: String, prompt: String, images: [String]) throws {
        var params: [String: Any] = ["session": id, "prompt": prompt]
        if !images.isEmpty { params["images"] = images }
        _ = try PuckDaemonConnection(socketPath: socketPath).request("session.turn", params: params)
    }

    public func decide(_ id: String, callID: String, decision: String) throws {
        try decide(id, callID: callID, decision: decision, reason: nil)
    }

    public func decide(_ id: String, callID: String, decision: String, reason: String?) throws {
        var params: [String: Any] = ["session": id, "call_id": callID, "decision": decision]
        if let reason, !reason.isEmpty { params["reason"] = reason }
        _ = try PuckDaemonConnection(socketPath: socketPath).request("session.decide", params: params)
    }

    public func answer(_ id: String, callID: String, selections: [PuckQuestionSelection]) throws {
        _ = try PuckDaemonConnection(socketPath: socketPath).request(
            "session.answer", params: ["session": id, "call_id": callID,
                                       "selections": selections.map(\.wireValue)])
    }

    public func plan(_ id: String) throws -> String? {
        let value = try PuckDaemonConnection(socketPath: socketPath).request("session.plan", params: ["session": id])
        guard let object = value as? [String: Any], object["plan"] is String || object["plan"] is NSNull else {
            throw PuckDaemonError.invalidResponse("plan")
        }
        return object["plan"] as? String
    }

    public func reject(_ id: String, callID: String, reason: String) throws {
        _ = try PuckDaemonConnection(socketPath: socketPath).request(
            "session.reject", params: ["session": id, "call_id": callID, "reason": reason,
                                       "actor": ["name": "Banyan", "kind": "banyan"]])
    }

    public func events(_ id: String, after: UInt64? = nil) throws -> PuckEventBatch {
        var params: [String: Any] = ["session": id]
        if let after { params["after"] = after }
        let value = try PuckDaemonConnection(socketPath: socketPath).request("session.events", params: params)
        guard let object = value as? [String: Any] else { throw PuckDaemonError.invalidResponse("events") }
        return try PuckEventBatch(object)
    }

    /// `attach` and `events` return bounded replay pages. Catch up to the
    /// cursor captured by attach before consuming its live notification stream.
    public func replay(_ id: String, initial: PuckEventBatch, after: UInt64 = 0) throws -> [PuckSessionEvent] {
        var events = initial.events
        var cursor = events.last?.cursor ?? after
        func trim() {
            var bytes = events.reduce(0) { $0 + $1.retainedByteCount }
            while !events.isEmpty && (events.count > 500 || bytes > 2 * 1_048_576) {
                bytes -= events.removeFirst().retainedByteCount
            }
        }
        trim()
        while cursor < initial.cursor {
            let page = try self.events(id, after: cursor)
            guard let next = page.events.last?.cursor, next > cursor else {
                throw PuckDaemonError.invalidResponse("replay cursor did not advance")
            }
            events.append(contentsOf: page.events)
            trim()
            cursor = next
        }
        return events
    }

    public func attach(_ id: String, after: UInt64? = nil) throws -> (PuckDaemonConnection, PuckAttachedSession) {
        let connection = try PuckDaemonConnection(socketPath: socketPath)
        var params: [String: Any] = ["session": id]
        if let after { params["after"] = after }
        let value = try connection.request("session.attach", params: params)
        guard let object = value as? [String: Any] else { throw PuckDaemonError.invalidResponse("attach") }
        return (connection, try PuckAttachedSession(object))
    }

    /// Read a live notification and fill any cursor gap from persisted events.
    /// A slow client may receive `lagged` after the broadcast queue overflows;
    /// that marker is never rendered as session content.
    public func receive(_ connection: PuckDaemonConnection, session id: String,
                        after cursor: UInt64) throws -> [PuckSessionEvent]? {
        guard let live = try connection.nextEvent() else { return nil }
        var events: [PuckSessionEvent] = []
        if live.kind == "lagged" || live.cursor > cursor + 1 {
            let page = try self.events(id, after: cursor)
            events = try replay(id, initial: page, after: cursor)
        }
        let last = events.last?.cursor ?? cursor
        if live.kind != "lagged" && (live.transient || live.cursor > last) {
            events.append(live)
        }
        if live.kind == "lagged" { events.append(live) }
        return events
    }
}

extension PuckDaemonClient: PuckDaemonService {
    public func create(id: String, provider: String, account: String?, model: String?,
                       workspace: String) throws -> PuckSessionSummary {
        try create(id: id, provider: provider, account: account, model: model,
                   workspace: workspace, settings: [:])
    }

    /// Events that change what a session is waiting on, so a follower refreshes
    /// the summary after one instead of re-deriving it from the event stream.
    static let summaryEventKinds: Set<String> = [
        "turn_started", "turn_done", "turn_error", "approval_pending", "approval_decided",
        "blocked_on_question", "question_answered", "hibernated",
    ]

    public func follow(_ id: String) -> AsyncThrowingStream<PuckSessionUpdate, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            let attachment = PuckFollowAttachment()
            continuation.onTermination = { _ in attachment.cancel() }
            // The socket read blocks until the daemon publishes, which can be
            // minutes for an idle session. A dedicated thread keeps that wait
            // off the cooperative pool, whose few threads every task shares.
            let thread = Thread {
                do {
                    let connection = try PuckDaemonConnection(socketPath: socketPath)
                    guard attachment.adopt(connection) else { return }
                    let value = try connection.request("session.attach", params: ["session": id])
                    guard let object = value as? [String: Any] else { throw PuckDaemonError.invalidResponse("attach") }
                    let attached = try PuckAttachedSession(object)
                    let replayed = attached.hasPagedHistory ? [] : try replay(id, initial: attached.batch)
                    continuation.yield(.attached(attached.summary, replayed))
                    if attached.hasPagedHistory { continuation.yield(.history(try history(id))) }
                    var cursor = attached.hasPagedHistory ? attached.batch.cursor : (replayed.last?.cursor ?? attached.batch.cursor)
                    while let next = try receive(connection, session: id, after: cursor) {
                        guard let last = next.last else { continue }
                        cursor = max(cursor, next.map(\.cursor).max() ?? last.cursor)
                        let yielded = continuation.yield(.events(next))
                        if case .dropped = yielded {
                            continuation.finish(throwing: PuckDaemonError.unavailable("Event consumer lagged; reconnect to refresh history"))
                            attachment.cancel(); return
                        }
                        if attached.hasPagedHistory && next.contains(where: { $0.kind == "turn_done" || $0.kind == "lagged" }) {
                            continuation.yield(.history(try history(id)))
                        }
                        if next.contains(where: { Self.summaryEventKinds.contains($0.kind) }) {
                            continuation.yield(.summary(try get(id)))
                        }
                    }
                    continuation.finish()
                } catch {
                    // A cancelled follower closed its own socket; that read
                    // error is the detach, not a failure worth reporting.
                    if attachment.isCancelled {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
            thread.name = "puck-follow"
            thread.start()
        }
    }
}

/// Lets a stream cancelled from any thread close the socket its reader is
/// blocked on, including one cancelled before the attach finished connecting.
private final class PuckFollowAttachment: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: PuckDaemonConnection?
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// Returns false when the follower was already cancelled; the connection is
    /// closed at once so the daemon drops the subscription.
    func adopt(_ connection: PuckDaemonConnection) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else {
            connection.disconnect()
            return false
        }
        self.connection = connection
        return true
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        connection?.disconnect()
    }
}
