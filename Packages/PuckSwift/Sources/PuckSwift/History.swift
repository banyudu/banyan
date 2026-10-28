import Foundation

public enum PuckEngine: String, Codable, Sendable { case codex, native }
public struct PuckProtocolVersion: Codable, Sendable { public let major: Int; public let minor: Int }
public struct PuckServerError: Codable, Sendable {
    public let code: String
    public let message: String
    public init(code: String, message: String) { self.code = code; self.message = message }
}
public struct PuckEngineCapabilities: Codable, Sendable {
    public let engine: PuckEngine
    public let ownsCodingLoop: Bool
    public let replacesBuiltinTools: Bool
    public let exactParkedRecovery: Bool
    public let pagedHistory: String
    public let addingCustomTools: Bool
    enum CodingKeys: String, CodingKey {
        case engine, ownsCodingLoop = "owns_coding_loop", replacesBuiltinTools = "replaces_builtin_tools"
        case exactParkedRecovery = "exact_parked_recovery", pagedHistory = "paged_history", addingCustomTools = "adding_custom_tools"
    }
}
public struct PuckCapabilities: Decodable, Sendable {
    public let version: PuckProtocolVersion
    public let engines: [PuckEngine]
    public let defaultEngine: PuckEngine
    public let features: [String]
    public let engineCapabilities: [PuckEngineCapabilities]?
    enum CodingKeys: String, CodingKey { case version = "protocol", engines, defaultEngine = "default_engine", features, engineCapabilities = "engine_capabilities" }
}
public struct PuckResources: Codable, Sendable {
    public let sessions: Int; public let active: Int; public let queued: Int
    public let parked: Int; public let hibernated: Int; public let workers: Int
    public let loadedThreads: Int; public let activeLimit: Int; public let queueLimit: Int
    public let loadedThreadsPerAccount: Int?
    public let loadedThreadsTotal: Int?
    enum CodingKeys: String, CodingKey { case sessions, active, queued, parked, hibernated, workers
        case loadedThreads = "loaded_threads", activeLimit = "active_limit", queueLimit = "queue_limit", loadedThreadsPerAccount = "loaded_threads_per_account", loadedThreadsTotal = "loaded_threads_total" }
}
public struct PuckHistoryItem: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let turnID: String?
    public let kind: String
    public let text: String
    public let truncated: Bool
    enum CodingKeys: String, CodingKey { case id, kind, text, truncated; case turnID = "turn_id" }
    public init(id: String, turnID: String? = nil, kind: String, text: String, truncated: Bool = false) {
        self.id = id; self.turnID = turnID; self.kind = kind; self.text = text; self.truncated = truncated
    }
}
public struct PuckHistoryPage: Codable, Sendable {
    public let session: String
    public let source: String
    public let items: [PuckHistoryItem]
    public let nextCursor: String?
    public let order: String
    enum CodingKeys: String, CodingKey { case session, source, items, order; case nextCursor = "next_cursor" }
    public init(session: String, source: String, items: [PuckHistoryItem], nextCursor: String?, order: String = "desc") {
        self.session = session; self.source = source; self.items = items; self.nextCursor = nextCursor; self.order = order
    }
}

/// A bounded chronological display window. Loading older pages evicts newer
/// content; loading the latest page restores the live window. Stable IDs merge
/// reconnects without duplicating rows. The embedding host owns global budgets.
public struct PuckHistoryWindow: Sendable {
    public private(set) var items: [PuckHistoryItem] = []
    public let maxItems: Int
    public let maxBytes: Int
    public var byteCount: Int { items.reduce(0) { $0 + $1.text.utf8.count + $1.id.utf8.count + 128 } }
    public init(maxItems: Int = 200, maxBytes: Int = 2 * 1_048_576) {
        self.maxItems = max(1, maxItems); self.maxBytes = max(1024, maxBytes)
    }
    public mutating func replace(with page: PuckHistoryPage) {
        items = []; merge(page, older: false)
    }
    public mutating func merge(_ page: PuckHistoryPage, older: Bool) {
        let incoming = page.order == "desc" ? Array(page.items.reversed()) : page.items
        var seen = Set(items.map(\.id)); let additions = incoming.filter { seen.insert($0.id).inserted }
        items = older ? additions + items : items + additions
        while items.count > maxItems || byteCount > maxBytes {
            if items.isEmpty { break }
            if older { items.removeLast() } else { items.removeFirst() }
        }
    }
    public mutating func clear() { items = [] }
}

public enum PuckApproval: String, Codable, Sendable { case ask, auto, yolo, deny }
public enum PuckSandbox: String, Codable, Sendable { case readOnly = "read-only", workspaceWrite = "workspace-write" }
public struct PuckSessionSettings: Encodable, Sendable {
    public var approval: PuckApproval = .ask
    public var sandbox: PuckSandbox = .workspaceWrite
    public var exec: Bool = true
    public var fetch: Bool = true
    public var search: Bool = true
    public var maxIterations: Int = 64
    public var contextBytes: Int = 1_048_576
    enum CodingKeys: String, CodingKey { case approval, sandbox, exec, fetch, search
        case maxIterations = "max_iterations", contextBytes = "context_bytes" }
    public init() {}
}
public struct PuckSessionOptions: Encodable, Sendable {
    public var id: String?
    public var engine: PuckEngine = .codex
    public var provider: String = "codex"
    public var account: String?
    public var workspace: String
    public var model: String?
    public var instructions: String?
    public var settings = PuckSessionSettings()
    public init(workspace: String) { self.workspace = workspace }
}

extension PuckDaemonClient {
    private func decode<T: Decodable>(_ type: T.Type, method: String, params: [String: Any] = [:]) throws -> T {
        let value = try PuckDaemonConnection(socketPath: socketPath).request(method, params: params)
        return try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value))
    }
    public func capabilities() throws -> PuckCapabilities {
        let result = try decode(PuckCapabilities.self, method: "daemon.capabilities")
        guard result.version.major == 2 else { throw PuckDaemonError.rejected("Unsupported Puck protocol major \(result.version.major)") }
        return result
    }
    public func resources() throws -> PuckResources { try decode(PuckResources.self, method: "daemon.resources") }
    public func history(_ id: String, cursor: String? = nil, limit: Int = 50) throws -> PuckHistoryPage {
        guard (1...100).contains(limit) else { throw PuckDaemonError.rejected("History limit must be 1...100") }
        var params: [String: Any] = ["session": id, "limit": limit]
        if let cursor { params["cursor"] = cursor }
        return try decode(PuckHistoryPage.self, method: "session.history", params: params)
    }
    public func create(_ options: PuckSessionOptions) throws -> PuckSessionSummary {
        _ = try capabilities()
        let params = try JSONSerialization.jsonObject(with: JSONEncoder().encode(options)) as! [String: Any]
        let value = try PuckDaemonConnection(socketPath: socketPath).request("session.create", params: params)
        guard let object = value as? [String: Any] else { throw PuckDaemonError.invalidResponse("summary") }
        return try PuckSessionSummary(object)
    }
    public func cancel(_ id: String) throws {
        _ = try PuckDaemonConnection(socketPath: socketPath).request("session.cancel", params: ["session": id])
    }
    public func suspend(_ id: String) throws {
        _ = try PuckDaemonConnection(socketPath: socketPath).request("session.suspend", params: ["session": id])
    }
    public func compact(_ id: String) throws {
        _ = try PuckDaemonConnection(socketPath: socketPath).request("session.compact", params: ["session": id])
    }
}
extension PuckDaemonService {
    public func history(_ id: String, cursor: String?, limit: Int) throws -> PuckHistoryPage {
        throw PuckDaemonError.rejected("This client does not support paged history")
    }
}

/// Async client facade. RPC work stays off the caller's executor. Cancelling a
/// follow stream detaches it; cancelling a coding turn requires explicit cancel.
public struct PuckClient: Sendable {
    public let transport: PuckDaemonClient
    public init(socketPath: String) { transport = PuckDaemonClient(socketPath: socketPath) }
    public init(environment: [String: String] = ProcessInfo.processInfo.environment) { transport = PuckDaemonClient(environment: environment) }
    public func capabilities() async throws -> PuckCapabilities { try await PuckBackgroundIO.run { try transport.capabilities() } }
    public func resources() async throws -> PuckResources { try await PuckBackgroundIO.run { try transport.resources() } }
    public func create(_ options: PuckSessionOptions) async throws -> PuckSessionSummary { try await PuckBackgroundIO.run { try transport.create(options) } }
    public func list() async throws -> [PuckSessionSummary] { try await PuckBackgroundIO.run { try transport.list() } }
    public func get(_ id: String) async throws -> PuckSessionSummary { try await PuckBackgroundIO.run { try transport.get(id) } }
    public func turn(_ id: String, prompt: String) async throws { try await PuckBackgroundIO.run { try transport.turn(id, prompt: prompt) } }
    public func history(_ id: String, cursor: String? = nil, limit: Int = 50) async throws -> PuckHistoryPage { try await PuckBackgroundIO.run { try transport.history(id, cursor: cursor, limit: limit) } }
    public func decide(_ id: String, callID: String, decision: String) async throws { try await PuckBackgroundIO.run { try transport.decide(id, callID: callID, decision: decision) } }
    public func answer(_ id: String, callID: String, selections: [PuckQuestionSelection]) async throws { try await PuckBackgroundIO.run { try transport.answer(id, callID: callID, selections: selections) } }
    public func cancel(_ id: String) async throws { try await PuckBackgroundIO.run { try transport.cancel(id) } }
    public func suspend(_ id: String) async throws { try await PuckBackgroundIO.run { try transport.suspend(id) } }
    public func compact(_ id: String) async throws { try await PuckBackgroundIO.run { try transport.compact(id) } }
    public func follow(_ id: String) -> AsyncThrowingStream<PuckSessionUpdate, Error> { transport.follow(id) }
}
