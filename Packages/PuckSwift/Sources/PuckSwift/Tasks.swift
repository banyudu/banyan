import Foundation

/// A durable task is the stable unit of ownership. Attempts are disposable
/// sessions; a retry changes the attempt without changing the task identity.
public enum PuckTaskState: String, Codable, Sendable {
    case admitted, scheduled, running, waitingExternal = "waiting_external"
    case needsAttention = "needs_attention", readyForDecision = "ready_for_decision"
    case paused, closing, closed, failed, cancelled, superseded

    public var needsAttention: Bool {
        switch self {
        case .waitingExternal, .needsAttention, .readyForDecision: true
        default: false
        }
    }
}

public enum PuckAttemptState: String, Codable, Sendable {
    case scheduled, running, waitingExternal = "waiting_external", completed, failed
    case interrupted, cancelled, superseded
}

public struct PuckTaskSource: Codable, Sendable, Equatable {
    public var kind: String
    public var externalID: String
    public var url: String?
    enum CodingKeys: String, CodingKey { case kind, url; case externalID = "external_id" }
    public init(kind: String, externalID: String = "", url: String? = nil) {
        self.kind = kind; self.externalID = externalID; self.url = url
    }
}

public struct PuckAcceptanceCriterion: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var text: String
    public init(id: String, text: String) { self.id = id; self.text = text }
}

public struct PuckTaskBudget: Codable, Sendable, Equatable {
    public var maxTokens: UInt64?
    public var deadlineMS: UInt64?
    enum CodingKeys: String, CodingKey { case maxTokens = "max_tokens", deadlineMS = "deadline_ms" }
    public init(maxTokens: UInt64? = nil, deadlineMS: UInt64? = nil) {
        self.maxTokens = maxTokens; self.deadlineMS = deadlineMS
    }
}

public struct PuckTaskCapability: Codable, Sendable, Equatable {
    public var allowedSources: [String]
    public var repositories: [String]
    public var worktreeWrite: Bool
    public var branchPush: Bool
    public var prCreate: Bool
    public var prComment: Bool
    public var merge: Bool
    public var deploy: Bool
    public var trackerClose: Bool
    public var maxAttempts: Int
    public var maxConcurrency: Int
    public var budget: PuckTaskBudget
    public var leaseMS: UInt64

    enum CodingKeys: String, CodingKey {
        case repositories, merge, deploy, budget
        case allowedSources = "allowed_sources", worktreeWrite = "worktree_write"
        case branchPush = "branch_push", prCreate = "pr_create", prComment = "pr_comment"
        case trackerClose = "tracker_close", maxAttempts = "max_attempts"
        case maxConcurrency = "max_concurrency", leaseMS = "lease_ms"
    }

    public init(allowedSources: [String] = [], repositories: [String] = [],
                worktreeWrite: Bool = true, branchPush: Bool = false,
                prCreate: Bool = false, prComment: Bool = false, merge: Bool = false,
                deploy: Bool = false, trackerClose: Bool = false,
                maxAttempts: Int = 3, maxConcurrency: Int = 1,
                budget: PuckTaskBudget = .init(), leaseMS: UInt64 = 900_000) {
        self.allowedSources = allowedSources; self.repositories = repositories
        self.worktreeWrite = worktreeWrite; self.branchPush = branchPush
        self.prCreate = prCreate; self.prComment = prComment; self.merge = merge
        self.deploy = deploy; self.trackerClose = trackerClose
        self.maxAttempts = maxAttempts; self.maxConcurrency = maxConcurrency
        self.budget = budget; self.leaseMS = leaseMS
    }
}

public struct PuckSlackTaskProjection: Codable, Sendable, Equatable {
    public var channel: String
    public var threadTS: String
    public var lastProjectedRevision: UInt64
    public var lastFingerprint: String?
    enum CodingKeys: String, CodingKey {
        case channel
        case threadTS = "thread_ts", lastProjectedRevision = "last_projected_revision"
        case lastFingerprint = "last_fingerprint"
    }
}

public struct PuckTaskAttempt: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var taskID: String
    public var state: PuckAttemptState
    public var sessionID: String?
    public var workspace: String
    public var worktree: String?
    public var branch: String?
    public var baseSHA: String?
    public var engine: PuckEngine
    public var provider: String
    public var account: String?
    public var model: String?
    public var budget: PuckTaskBudget
    public var startedAtMS: UInt64
    public var endedAtMS: UInt64?
    public var heartbeatAtMS: UInt64
    public var leaseExpiresAtMS: UInt64
    public var evidenceIDs: [String]
    public var error: String?
    public var supersededBy: String?
    enum CodingKeys: String, CodingKey {
        case id, state, workspace, worktree, branch, engine, provider, account, model, budget, error
        case taskID = "task_id", sessionID = "session_id", baseSHA = "base_sha"
        case startedAtMS = "started_at_ms"
        case endedAtMS = "ended_at_ms", heartbeatAtMS = "heartbeat_at_ms"
        case leaseExpiresAtMS = "lease_expires_at_ms", evidenceIDs = "evidence_ids"
        case supersededBy = "superseded_by"
    }
}

public struct PuckEvidenceSource: Codable, Sendable, Equatable {
    public var kind: String
    public var reference: String
    public var url: String?
    public init(kind: String, reference: String = "", url: String? = nil) {
        self.kind = kind; self.reference = reference; self.url = url
    }
}

/// Arbitrary JSON carried by evidence. Kept typed so request/response values
/// remain Sendable without smuggling `Any` across concurrency boundaries.
public enum PuckJSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([PuckJSONValue])
    case object([String: PuckJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int64.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([PuckJSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: PuckJSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

public struct PuckTaskEvidence: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var taskID: String
    public var attemptID: String?
    public var kind: String
    public var source: PuckEvidenceSource
    public var observedAtMS: UInt64
    public var taskRevision: UInt64
    public var acceptanceHash: String
    public var sourceSHA: String?
    public var headSHA: String?
    public var payload: PuckJSONValue
    public var payloadHash: String
    public var stale: Bool
    enum CodingKeys: String, CodingKey {
        case id, kind, source, payload, stale
        case taskID = "task_id", attemptID = "attempt_id", observedAtMS = "observed_at_ms"
        case taskRevision = "task_revision", acceptanceHash = "acceptance_hash"
        case sourceSHA = "source_sha", headSHA = "head_sha", payloadHash = "payload_hash"
    }
}

public struct PuckTaskActor: Codable, Sendable, Equatable {
    public var name: String
    public var kind: String
    public init(name: String, kind: String = "swift") { self.name = name; self.kind = kind }
}

public struct PuckTaskDecision: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var taskID: String
    public var kind: String
    public var outcome: String
    public var actor: PuckTaskActor
    public var rationale: String
    public var evidenceIDs: [String]
    public var evidenceHashes: [String]
    public var taskRevision: UInt64
    public var createdAtMS: UInt64
    enum CodingKeys: String, CodingKey {
        case id, kind, outcome, actor, rationale
        case taskID = "task_id", evidenceIDs = "evidence_ids", evidenceHashes = "evidence_hashes"
        case taskRevision = "task_revision", createdAtMS = "created_at_ms"
    }

    public var isAccepted: Bool {
        outcome.lowercased() == "accepted"
            || (kind.lowercased() == "accept" && outcome.lowercased() != "rejected")
    }
}

public struct PuckTaskCloseout: Codable, Sendable, Equatable {
    public var decisionID: String
    public var capability: String
    public var effectIdempotencyKey: String
    public var readback: String
    public var actor: PuckTaskActor
    public var completedAtMS: UInt64
    enum CodingKeys: String, CodingKey {
        case capability, readback, actor
        case decisionID = "decision_id", effectIdempotencyKey = "effect_idempotency_key"
        case completedAtMS = "completed_at_ms"
    }
}

public struct PuckTask: Codable, Sendable, Equatable, Identifiable {
    public var schema: Int
    public var id: String
    public var revision: UInt64
    public var state: PuckTaskState
    public var source: PuckTaskSource
    public var title: String
    public var body: String
    public var repository: String?
    public var workspace: String
    public var owner: String?
    public var priority: String?
    public var candidateKeys: [String]
    public var acceptance: [PuckAcceptanceCriterion]
    public var acceptanceHash: String
    public var headSHA: String?
    public var capability: PuckTaskCapability
    public var attempts: [PuckTaskAttempt]
    public var currentAttempt: String?
    public var evidence: [PuckTaskEvidence]
    public var decisions: [PuckTaskDecision]
    public var blocker: String?
    public var nextAction: String?
    public var slack: PuckSlackTaskProjection?
    public var closeout: PuckTaskCloseout?
    public var createdAtMS: UInt64
    public var updatedAtMS: UInt64

    enum CodingKeys: String, CodingKey {
        case schema, id, revision, state, source, title, body, repository, workspace, owner
        case priority, acceptance, evidence, decisions, blocker, slack, closeout
        case candidateKeys = "candidate_keys", acceptanceHash = "acceptance_hash"
        case headSHA = "head_sha", capability, attempts, currentAttempt = "current_attempt"
        case nextAction = "next_action", createdAtMS = "created_at_ms", updatedAtMS = "updated_at_ms"
    }

    public var currentAttemptValue: PuckTaskAttempt? {
        guard let currentAttempt else { return nil }
        return attempts.first { $0.id == currentAttempt }
    }

    public var acceptedDecision: PuckTaskDecision? {
        guard state == .readyForDecision,
              let decision = decisions.last(where: { $0.kind != "acceptance_update" }),
              decision.isAccepted else { return nil }
        return decision
    }
}

public struct PuckTaskCandidate: Codable, Sendable, Equatable {
    public var source: PuckTaskSource
    public var title: String
    public var body: String
    public var repository: String?
    public var workspace: String
    public var owner: String?
    public var priority: String?
    public var dedupeKeys: [String]
    public var acceptance: [PuckAcceptanceCriterion]
    public var capability: PuckTaskCapability
    enum CodingKeys: String, CodingKey {
        case source, title, body, repository, workspace, owner, priority, acceptance, capability
        case dedupeKeys = "dedupe_keys"
    }
    public init(source: PuckTaskSource, title: String, body: String = "",
                repository: String? = nil, workspace: String, owner: String? = nil,
                priority: String? = nil, dedupeKeys: [String] = [],
                acceptance: [PuckAcceptanceCriterion] = [],
                capability: PuckTaskCapability = .init()) {
        self.source = source; self.title = title; self.body = body; self.repository = repository
        self.workspace = workspace; self.owner = owner; self.priority = priority
        self.dedupeKeys = dedupeKeys; self.acceptance = acceptance; self.capability = capability
    }
}

public struct PuckTaskAdmitRequest: Codable, Sendable, Equatable {
    public var candidateID: String?
    public var candidate: PuckTaskCandidate
    public var autoStart: Bool
    public var prompt: String?
    enum CodingKeys: String, CodingKey {
        case candidate, prompt
        case candidateID = "candidate_id", autoStart = "auto_start"
    }
    public init(candidateID: String? = nil, candidate: PuckTaskCandidate,
                autoStart: Bool = false, prompt: String? = nil) {
        self.candidateID = candidateID; self.candidate = candidate; self.autoStart = autoStart
        self.prompt = prompt
    }
}

public struct PuckTaskAdmission: Codable, Sendable, Equatable {
    public var task: PuckTask
    public var candidateID: String
    public var attemptID: String?
    public var sessionID: String?
    public var deduplicated: Bool
    enum CodingKeys: String, CodingKey {
        case task, deduplicated
        case candidateID = "candidate_id", attemptID = "attempt_id", sessionID = "session_id"
    }
}

public struct PuckTaskRun: Codable, Sendable, Equatable {
    public var task: PuckTask
    public var attemptID: String
    public var sessionID: String
    enum CodingKeys: String, CodingKey {
        case task
        case attemptID = "attempt_id", sessionID = "session_id"
    }
}

public struct PuckTaskListFilter: Codable, Sendable, Equatable {
    public var state: PuckTaskState?
    public var needsAttention: Bool
    public var sourceKind: String?
    enum CodingKeys: String, CodingKey {
        case state
        case needsAttention = "needs_attention", sourceKind = "source_kind"
    }
    public init(state: PuckTaskState? = nil, needsAttention: Bool = false, sourceKind: String? = nil) {
        self.state = state; self.needsAttention = needsAttention; self.sourceKind = sourceKind
    }
}

public struct PuckAddTaskEvidenceRequest: Codable, Sendable, Equatable {
    public var taskID: String
    public var attemptID: String?
    public var kind: String
    public var source: PuckEvidenceSource
    public var sourceSHA: String?
    public var headSHA: String?
    public var payload: PuckJSONValue
    public var expectedRevision: UInt64?
    public var acceptanceHash: String?
    enum CodingKeys: String, CodingKey {
        case kind, source, payload
        case taskID = "task_id", attemptID = "attempt_id", sourceSHA = "source_sha"
        case headSHA = "head_sha", expectedRevision = "expected_revision"
        case acceptanceHash = "acceptance_hash"
    }
    public init(taskID: String, attemptID: String? = nil, kind: String,
                source: PuckEvidenceSource, sourceSHA: String? = nil, headSHA: String? = nil,
                payload: PuckJSONValue = .object([:]), expectedRevision: UInt64? = nil,
                acceptanceHash: String? = nil) {
        self.taskID = taskID; self.attemptID = attemptID; self.kind = kind; self.source = source
        self.sourceSHA = sourceSHA; self.headSHA = headSHA; self.payload = payload
        self.expectedRevision = expectedRevision; self.acceptanceHash = acceptanceHash
    }
}

public struct PuckTaskDecisionRequest: Codable, Sendable, Equatable {
    public var taskID: String
    public var kind: String
    public var outcome: String
    public var actor: PuckTaskActor
    public var rationale: String
    public var evidenceIDs: [String]
    public var expectedRevision: UInt64?
    enum CodingKeys: String, CodingKey {
        case kind, outcome, actor, rationale
        case taskID = "task_id", evidenceIDs = "evidence_ids", expectedRevision = "expected_revision"
    }
    public init(taskID: String, kind: String, outcome: String, actor: PuckTaskActor,
                rationale: String = "", evidenceIDs: [String] = [], expectedRevision: UInt64? = nil) {
        self.taskID = taskID; self.kind = kind; self.outcome = outcome; self.actor = actor
        self.rationale = rationale; self.evidenceIDs = evidenceIDs
        self.expectedRevision = expectedRevision
    }
}

public struct PuckTaskCloseRequest: Codable, Sendable, Equatable {
    public var taskID: String
    public var decisionID: String
    public var capability: String
    public var effectIdempotencyKey: String
    public var readback: String
    public var actor: PuckTaskActor
    enum CodingKeys: String, CodingKey {
        case capability, readback, actor
        case taskID = "task_id", decisionID = "decision_id"
        case effectIdempotencyKey = "effect_idempotency_key"
    }
    public init(taskID: String, decisionID: String, effectIdempotencyKey: String,
                capability: String = "task", readback: String = "", actor: PuckTaskActor) {
        self.taskID = taskID; self.decisionID = decisionID; self.capability = capability
        self.effectIdempotencyKey = effectIdempotencyKey; self.readback = readback; self.actor = actor
    }
}

public struct PuckTaskEvent: Codable, Sendable, Equatable {
    public var cursor: UInt64
    public var kind: String
    public var taskID: String
    public var revision: UInt64
    public var state: PuckTaskState
    public var attemptID: String?
    public var atMS: UInt64
    enum CodingKeys: String, CodingKey {
        case cursor, kind, revision, state
        case taskID = "task_id", attemptID = "attempt_id", atMS = "at_ms"
    }
}

public struct PuckTaskEventReplay: Codable, Sendable, Equatable {
    public var cursor: UInt64
    public var events: [PuckTaskEvent]
}

public struct PuckTaskReconcileReport: Codable, Sendable, Equatable {
    public var checked: Int
    public var changed: Int
    public var externalSkipped: Bool
    enum CodingKeys: String, CodingKey {
        case checked, changed
        case externalSkipped = "external_skipped"
    }
}

extension PuckDaemonClient {
    private func taskParams<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PuckDaemonError.invalidResponse("task request")
        }
        return object
    }

    private func taskDecode<T: Decodable>(_ type: T.Type, method: String,
                                          params: [String: Any] = [:]) throws -> T {
        let value = try PuckDaemonConnection(socketPath: socketPath).request(method, params: params)
        let data = try JSONSerialization.data(withJSONObject: value)
        return try JSONDecoder().decode(type, from: data)
    }

    public func tasks(filter: PuckTaskListFilter = .init()) throws -> [PuckTask] {
        try taskDecode([PuckTask].self, method: "task.list", params: try taskParams(filter))
    }

    public func task(_ id: String) throws -> PuckTask {
        try taskDecode(PuckTask.self, method: "task.get", params: ["task": id])
    }

    public func admitTask(_ request: PuckTaskAdmitRequest) throws -> PuckTaskAdmission {
        try taskDecode(PuckTaskAdmission.self, method: "task.admit", params: try taskParams(request))
    }

    public func retryTask(_ id: String, reason: String = "retry requested",
                          instruction: String? = nil) throws -> PuckTaskRun {
        var params: [String: Any] = ["task": id, "reason": reason]
        if let instruction { params["prompt"] = instruction }
        return try taskDecode(PuckTaskRun.self, method: "task.retry", params: params)
    }

    public func pauseTask(_ id: String, reason: String) throws -> PuckTask {
        try taskDecode(PuckTask.self, method: "task.pause", params: ["task": id, "reason": reason])
    }

    public func cancelTask(_ id: String, reason: String) throws -> PuckTask {
        try taskDecode(PuckTask.self, method: "task.cancel", params: ["task": id, "reason": reason])
    }

    public func addTaskEvidence(_ request: PuckAddTaskEvidenceRequest) throws -> PuckTask {
        try taskDecode(PuckTask.self, method: "task.evidence", params: try taskParams(request))
    }

    public func decideTask(_ request: PuckTaskDecisionRequest) throws -> PuckTask {
        try taskDecode(PuckTask.self, method: "task.decide", params: try taskParams(request))
    }

    public func closeTask(_ request: PuckTaskCloseRequest) throws -> PuckTask {
        try taskDecode(PuckTask.self, method: "task.close", params: try taskParams(request))
    }

    public func bindTaskToSlack(_ id: String, channel: String, threadTS: String) throws -> PuckTask {
        try taskDecode(PuckTask.self, method: "task.slack.bind",
                       params: ["task": id, "channel": channel, "thread_ts": threadTS])
    }

    public func reconcileTasks() throws -> PuckTaskReconcileReport {
        try taskDecode(PuckTaskReconcileReport.self, method: "task.reconcile")
    }

    public func taskEvents(after: UInt64 = 0, limit: Int = 250) throws -> PuckTaskEventReplay {
        guard (1...1000).contains(limit) else {
            throw PuckDaemonError.rejected("Task event limit must be 1...1000")
        }
        return try taskDecode(PuckTaskEventReplay.self, method: "task.events",
                              params: ["after": after, "limit": limit])
    }
}

extension PuckClient {
    public func tasks(_ filter: PuckTaskListFilter = .init()) async throws -> [PuckTask] {
        try await PuckBackgroundIO.run { try transport.tasks(filter: filter) }
    }
    public func task(_ id: String) async throws -> PuckTask {
        try await PuckBackgroundIO.run { try transport.task(id) }
    }
    public func admitTask(_ request: PuckTaskAdmitRequest) async throws -> PuckTaskAdmission {
        try await PuckBackgroundIO.run { try transport.admitTask(request) }
    }
    public func retryTask(_ id: String, reason: String = "retry requested",
                          instruction: String? = nil) async throws -> PuckTaskRun {
        try await PuckBackgroundIO.run {
            try transport.retryTask(id, reason: reason, instruction: instruction)
        }
    }
    public func pauseTask(_ id: String, reason: String) async throws -> PuckTask {
        try await PuckBackgroundIO.run { try transport.pauseTask(id, reason: reason) }
    }
    public func cancelTask(_ id: String, reason: String) async throws -> PuckTask {
        try await PuckBackgroundIO.run { try transport.cancelTask(id, reason: reason) }
    }
    public func addTaskEvidence(_ request: PuckAddTaskEvidenceRequest) async throws -> PuckTask {
        try await PuckBackgroundIO.run { try transport.addTaskEvidence(request) }
    }
    public func decideTask(_ request: PuckTaskDecisionRequest) async throws -> PuckTask {
        try await PuckBackgroundIO.run { try transport.decideTask(request) }
    }
    public func closeTask(_ request: PuckTaskCloseRequest) async throws -> PuckTask {
        try await PuckBackgroundIO.run { try transport.closeTask(request) }
    }
    public func reconcileTasks() async throws -> PuckTaskReconcileReport {
        try await PuckBackgroundIO.run { try transport.reconcileTasks() }
    }
    public func taskEvents(after: UInt64 = 0, limit: Int = 250) async throws -> PuckTaskEventReplay {
        try await PuckBackgroundIO.run { try transport.taskEvents(after: after, limit: limit) }
    }
}
