import Foundation

/// Durable work owning a session. Raw kind/state values preserve compatibility
/// with newer daemons; clients choose their own sidebar membership.
public struct PuckSessionOwner: Equatable, Sendable {
    public let kind: String
    public let title: String
    public let state: String
    public let revision: UInt64
    public let taskID: String?
    public let attemptID: String?
    public let attemptState: String?
    public let isCurrent: Bool?
    public let jobID: String?
    public let runID: String?
    public let runRevision: UInt64?
    public let isLatest: Bool?

    public init(_ object: [String: Any]) throws {
        guard let kind = object["kind"] as? String,
              let title = object["title"] as? String,
              let state = object["state"] as? String,
              let revision = object["revision"] as? NSNumber else {
            throw PuckDaemonError.invalidResponse("session owner")
        }
        self.kind = kind
        self.title = title
        self.state = state
        self.revision = revision.uint64Value
        taskID = object["task_id"] as? String
        attemptID = object["attempt_id"] as? String
        attemptState = object["attempt_state"] as? String
        isCurrent = object["is_current"] as? Bool
        jobID = object["job_id"] as? String
        runID = object["run_id"] as? String
        runRevision = (object["run_revision"] as? NSNumber)?.uint64Value
        isLatest = object["is_latest"] as? Bool
        if kind == "task", taskID == nil || attemptID == nil || attemptState == nil || isCurrent == nil {
            throw PuckDaemonError.invalidResponse("task session owner")
        }
        if kind == "job", jobID == nil || runID == nil || runRevision == nil || isLatest == nil {
            throw PuckDaemonError.invalidResponse("job session owner")
        }
    }
}

public struct PuckSessionAttention: Equatable, Sendable {
    public let scope: String
    public let kind: String
    public let requiresHuman: Bool

    public init(_ object: [String: Any]) throws {
        guard let scope = object["scope"] as? String,
              let kind = object["kind"] as? String,
              let required = object["requires_human"] as? Bool else {
            throw PuckDaemonError.invalidResponse("session attention")
        }
        self.scope = scope
        self.kind = kind
        requiresHuman = required
    }
}

public struct PuckSessionPresentation: Equatable, Sendable {
    public let title: String?
    /// Nil is an explicitly unowned/unmapped session. A nil presentation on a
    /// summary instead means that the daemon did not supply this contract.
    public let owner: PuckSessionOwner?
    public let attention: [PuckSessionAttention]

    public init(_ object: [String: Any]) throws {
        title = object["title"] as? String
        owner = try (object["owner"] as? [String: Any]).map(PuckSessionOwner.init)
        attention = try (object["attention"] as? [[String: Any]] ?? []).map(PuckSessionAttention.init)
    }
}
