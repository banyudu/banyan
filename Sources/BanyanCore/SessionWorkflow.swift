import Foundation

/// Issue delivery is independent of the process supervisor's status.
public struct SessionWorkflow: Codable, Equatable, Sendable {
    public enum State: String, Codable, CaseIterable, Sendable {
        case working, waiting, verified, paused, cancelled
        case needsYou = "needs-you"

        public var label: String {
            switch self {
            case .working: return "Working"
            case .waiting: return "Auto-waiting"
            case .needsYou: return "Needs you"
            case .verified: return "Verified"
            case .paused: return "Paused"
            case .cancelled: return "Cancelled"
            }
        }

        public var permitsWake: Bool { self == .working || self == .waiting }
        public var permitsClose: Bool { [.verified, .paused, .cancelled].contains(self) }
    }

    public struct Wake: Codable, Equatable, Sendable {
        public enum Status: String, Codable, Sendable {
            case pending, delivered, uncertain
            case notDelivered = "not-delivered"
        }
        public let id: String
        public var status: Status
        public init(id: String, status: Status) { self.id = id; self.status = status }
    }

    public let owner: String
    public let jobID: String
    public let revision: Int
    public let state: State
    public let detail: String
    public var wake: Wake?

    public init(owner: String, jobID: String, revision: Int, state: State, detail: String = "", wake: Wake? = nil) {
        self.owner = owner; self.jobID = jobID; self.revision = revision
        self.state = state; self.detail = detail; self.wake = wake
    }

    public func replacing(_ next: SessionWorkflow) throws -> SessionWorkflow {
        guard owner == next.owner, jobID == next.jobID else { throw WorkflowError.refused("workflow owner does not match") }
        guard next.revision >= revision else { throw WorkflowError.refused("stale workflow revision") }
        if next.revision == revision {
            guard state == next.state, detail == next.detail else { throw WorkflowError.refused("revision already has different content") }
            return self
        }
        var result = next
        result.wake = wake
        return result
    }

    /// A retry of a delivered wake is acknowledged without another side effect.
    /// Pending/uncertain receipts require inspection, never blind redelivery.
    public func shouldDeliver(jobID: String, revision: Int, wakeID: String) throws -> Bool {
        guard self.jobID == jobID else { throw WorkflowError.refused("workflow job does not match") }
        if let wake, wake.id == wakeID {
            if wake.status == .delivered { return false }
            guard wake.status == .notDelivered else { throw WorkflowError.refused("wake delivery is uncertain; inspect the conversation") }
        }
        guard self.revision == revision else { throw WorkflowError.refused("stale workflow revision") }
        guard state.permitsWake else { throw WorkflowError.refused("workflow is \(state.rawValue)") }
        guard wake?.status != .pending, wake?.status != .uncertain else {
            throw WorkflowError.refused("previous wake delivery is uncertain; inspect the conversation")
        }
        return true
    }
}

public enum WorkflowError: Error, LocalizedError {
    case refused(String)
    case notDelivered(String)
    public var errorDescription: String? {
        switch self { case .refused(let reason), .notDelivered(let reason): return reason }
    }
}

/// A separate throwing journal keeps continuation receipts out of best-effort
/// session snapshots. Persist the intent before any input/network side effect.
public struct SessionWorkflowJournal: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    private var storage: SessionJournalStorage<SessionWorkflow> {
        .init(directory: directory)
    }

    public func load(id: String) throws -> SessionWorkflow? {
        try storage.load(id: id)
    }

    public func save(_ workflow: SessionWorkflow, id: String) throws {
        try storage.save(workflow, id: id)
    }
}

public enum SessionWorkflowPolicy {
    public static func canRecover(observed: AgentAdmissionPaneInspection, current: AgentAdmissionPaneInspection) -> Bool {
        switch (observed, current) {
        case (.absent, .absent): return true
        case (.present(let before), .present(let after)):
            return before.isDead && after.isDead && before.paneID == after.paneID && before.rootPID == after.rootPID
        default: return false
        }
    }

    public static func canWake(status: SessionStatus, isSuspended: Bool, isFrozen: Bool,
                               isDeepSuspended: Bool, hasObservation: Bool, isAgent: Bool,
                               hasHumanPrompt: Bool = false, hasEmptyInput: Bool = false) -> Bool {
        isAgent && hasObservation && !isSuspended && !isFrozen && !isDeepSuspended
            && !hasHumanPrompt && ([.idle, .review].contains(status) || (status == .needInput && hasEmptyInput))
    }

    /// Used turns are need-input in the process supervisor. Require an empty
    /// native input row; never infer readiness merely from a quiet process.
    public static func hasEmptyInput(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if let index = lines.indices.last(where: { lines[$0].hasPrefix("›") || lines[$0].hasPrefix("❯") }) {
            let isCodexComposer = lines[index].hasPrefix("›")
            let draft = lines[index].dropFirst().trimmingCharacters(in: .whitespaces)
            guard index >= max(0, lines.count - 12),
                  draft.isEmpty || (isCodexComposer && draft == "Ask Codex to do anything") else { return false }
            return lines.dropFirst(index + 1).allSatisfy {
                // Footer-shaped rows must match the entire known layout, even
                // if a malformed suffix happens to contain a hint phrase.
                if isCodexComposer && $0.contains(" · ") && !$0.hasPrefix("? for shortcuts") {
                    return $0.range(
                        of: #"\A[^\s·][^·\r\n]* · [^\s·][^·\r\n]* · Context [0-9]{1,3}% used · weekly [0-9]{1,3}% left(?: · [^\s·\[\]](?:[^·\[\]\r\n]*[^\s·\[\]])? \[[A-Za-z0-9_-][A-Za-z0-9_.-]*\])?\z"#,
                        options: .regularExpression) != nil
                }
                return $0.isEmpty || $0.contains("for shortcuts") || $0.contains("context left")
                    || $0.contains("shift+tab to cycle") || $0.contains("ctrl+t to hide")
            }
        }
        // OpenCode's input block ends with its model/footer line. A draft,
        // picker or permission dialog contains other text inside this block.
        let block = lines.suffix(12).filter { $0.hasPrefix("┃") }
            .map { String($0.dropFirst()).trimmingCharacters(in: .whitespaces) }
        return block.count >= 2 && block.contains("") && block.allSatisfy {
            $0.isEmpty || $0.hasPrefix("Ask anything...") || ($0.contains(" · ") && !$0.contains("?"))
        }
    }

    public static func shouldCloseVerified(workflow: SessionWorkflow?, status: SessionStatus) -> Bool {
        workflow?.state == .verified && status != .closed && ![.running, .executing, .subagents, .longRunningShell, .asking, .needInput].contains(status)
    }
}

public struct WorkflowControlPayload: Decodable {
    public let apiVersion: String?
    public let id: String?
    public let owner: String?
    public let jobID: String?
    public let revision: LenientInt?
    public let state: String?
    public let detail: String?
    public let wakeID: String?
    public let text: String?
    public let outcome: String?

    public func workflow() throws -> SessionWorkflow {
        guard let id, !id.isEmpty, let owner, !owner.isEmpty, let jobID, !jobID.isEmpty,
              let revision = revision?.value, revision >= 0,
              let state = state.flatMap(SessionWorkflow.State.init(rawValue:)) else {
            throw WorkflowError.refused("id, owner, jobID, non-negative revision and valid state are required")
        }
        return SessionWorkflow(owner: owner, jobID: jobID, revision: revision, state: state, detail: detail ?? "")
    }
}
