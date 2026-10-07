import Foundation

/// Settings belong to the thread, not the shared server process. Reapply them
/// on resume: App Server may otherwise use its current global defaults.
public struct CodexThreadSettings: Codable, Equatable, Sendable {
    public var model: String?
    public var modelProvider: String?
    public var approvalPolicy: String
    public var sandbox: String
    public var config: [String: CodexJSONValue]

    public init(model: String? = nil, modelProvider: String? = nil,
                approvalPolicy: String = "on-request", sandbox: String = "workspace-write",
                config: [String: CodexJSONValue] = [:]) {
        self.model = model
        self.modelProvider = modelProvider
        self.approvalPolicy = approvalPolicy
        self.sandbox = sandbox
        self.config = config
    }

    func parameters(cwd: String) -> [String: CodexJSONValue] {
        var result: [String: CodexJSONValue] = [
            "cwd": .string(cwd), "approvalPolicy": .string(approvalPolicy),
            "sandbox": .string(sandbox), "config": .object(config)
        ]
        if let model { result["model"] = .string(model) }
        if let modelProvider { result["modelProvider"] = .string(modelProvider) }
        return result
    }
}

/// Persisted beside the Banyan row. A missing rollout never authorizes replacing
/// an existing ID. An uncertain start must be recovered explicitly via list/read.
public struct CodexThreadBinding: Codable, Equatable, Sendable {
    public var threadID: String?
    public let cwd: String
    public var settings: CodexThreadSettings
    public var creationAttempted: Bool

    public init(threadID: String? = nil, cwd: String, settings: CodexThreadSettings = .init(),
                creationAttempted: Bool = false) {
        self.threadID = threadID
        self.cwd = cwd
        self.settings = settings
        self.creationAttempted = creationAttempted || threadID != nil
    }
}

public enum CodexThreadConnection: Equatable, Sendable {
    case disconnected, connecting, subscribed, unsubscribed
    case writerConflict(String), unavailable(String), failed(String)

    public var message: String? {
        switch self {
        case .writerConflict(let message), .unavailable(let message), .failed(let message): return message
        case .disconnected: return "Reconnect to resume this Codex thread."
        default: return nil
        }
    }
}

public struct CodexThreadRuntime: Equatable, Sendable {
    public var type: String
    public var activeFlags: [String]

    public init(type: String = "unknown", activeFlags: [String] = []) {
        self.type = type
        self.activeFlags = activeFlags
    }

    init(_ value: CodexJSONValue?) {
        let object = value?.objectValue
        type = object?["type"]?.stringValue ?? "unknown"
        if case .array(let flags)? = object?["activeFlags"] {
            activeFlags = flags.compactMap(\.stringValue)
        } else { activeFlags = [] }
    }
}

/// Small injectable boundary; production uses the one Banyan-owned client.
public protocol CodexThreadService: Sendable {
    func connect() async throws
    func request(_ method: String, params: CodexJSONValue) async throws -> CodexJSONValue
    func events() async -> AsyncStream<CodexAppServerEvent>
    func setServerRequestHandler(_ handler: CodexAppServerClient.RequestHandler?) async
}

public extension CodexThreadService {
    func connect() async throws {}
}

extension CodexAppServerClient: CodexThreadService {}
