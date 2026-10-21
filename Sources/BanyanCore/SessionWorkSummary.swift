import Foundation

/// Read-only presentation joins. A process being idle does not mean its issue is done.
public struct SessionWorkNode: Sendable, Equatable {
    public let id: String
    public let parentID: String?
    public let title: String
    public let status: SessionStatus
    public let workflow: SessionWorkflow?
    public let background: Bool
    public let recoveryError: Bool
    public init(id: String, parentID: String?, title: String, status: SessionStatus,
                workflow: SessionWorkflow?, background: Bool = false, recoveryError: Bool = false) {
        self.id = id; self.parentID = parentID; self.title = title; self.status = status
        self.workflow = workflow; self.background = background; self.recoveryError = recoveryError
    }
}

public struct SessionWorkEntry: Identifiable, Sendable {
    public enum Kind: String, Sendable { case working, waiting, blocked, decision, paused, verified, cancelled, idle }
    public let id: String
    public let title: String
    public let identity: String
    public let kind: Kind
    public let label: String
    public let detail: String
    public let background: Bool
    public let job: WorkitJobSummary?
    public let managed: Bool
    public var needsAttention: Bool { kind == .blocked || kind == .decision }

    init(node: SessionWorkNode, job: WorkitJobSummary?) {
        id = node.id; title = node.title; background = node.background; managed = node.workflow != nil
        identity = node.workflow.map { "\($0.owner):\($0.jobID)" } ?? "session:\(node.id)"
        self.job = job
        if node.recoveryError {
            kind = .blocked; label = "Recovery needed"; detail = "The workflow journal could not be read. Inspect recovery before continuing."
        } else if let job, let display = job.display, let parsed = Kind(rawValue: display.kind), !display.label.isEmpty {
            kind = parsed; label = display.label; detail = job.stopReason ?? job.detail
        } else if let workflow = node.workflow {
            detail = job?.stopReason ?? job?.detail ?? workflow.detail
            switch workflow.state {
            case .working: kind = .working; label = "Working"
            case .waiting: kind = .waiting; label = "Waiting"
            case .needsYou: kind = .blocked; label = "Check job"
            case .paused: kind = .paused; label = "Paused"
            case .verified: kind = .verified; label = "Verified"
            case .cancelled: kind = .cancelled; label = "Cancelled"
            }
        } else {
            detail = "Conversation status; no managed issue completion is recorded."
            switch node.status {
            case .running, .executing, .subagents, .longRunningShell: kind = .working; label = "Working"
            case .asking: kind = .decision; label = "Input requested"
            case .failed: kind = .blocked; label = "Session failed"
            default: kind = .idle; label = "Idle"
            }
        }
    }
}

public struct SessionWorkSummary: Sendable {
    public let own: SessionWorkEntry
    public var descendants: [SessionWorkEntry] = []
    public var groupLabel: String {
        let counts = Dictionary(grouping: descendants, by: \.kind).mapValues(\.count)
        let names: [(SessionWorkEntry.Kind, String)] = [(.working, "working"), (.waiting, "waiting"),
            (.blocked, "blocked"), (.decision, "need input"), (.paused, "paused"), (.verified, "verified"), (.idle, "idle"), (.cancelled, "cancelled")]
        return names.compactMap { kind, name in counts[kind].map { "\($0) \(name)" } }.joined(separator: " · ")
    }
}

public enum SessionWorkTree {
    /// Evaluated once per relevant change by the store, never once per visible row.
    public static func summaries(nodes: [SessionWorkNode], overview: WorkitOverview?) -> [String: SessionWorkSummary] {
        let nodes = nodes.filter { $0.status != .closed }
        let byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let jobs = Dictionary((overview?.jobs ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [String: SessionWorkSummary] = [:]
        for node in byID.values {
            let job = node.workflow.flatMap { workflow -> WorkitJobSummary? in
                guard workflow.owner == "workit", let value = jobs[workflow.jobID], value.sessionID == node.id,
                      value.revision >= workflow.revision else { return nil }
                return value
            }
            result[node.id] = SessionWorkSummary(own: SessionWorkEntry(node: node, job: job))
        }
        var seen: [String: Set<String>] = [:]
        // Stable input order keeps child navigation predictable across refreshes.
        for node in nodes {
            guard let entry = result[node.id]?.own else { continue }
            var parent = node.parentID, visited: Set<String> = [node.id]
            while let id = parent, let ancestor = byID[id], visited.insert(id).inserted {
                if entry.identity != result[id]?.own.identity, seen[id, default: []].insert(entry.identity).inserted {
                    result[id]?.descendants.append(entry)
                }
                parent = ancestor.parentID
            }
        }
        return result
    }
}
