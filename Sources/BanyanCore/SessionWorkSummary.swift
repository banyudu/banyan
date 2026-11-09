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
    /// Why Banyan refused the owner's most recent wake, until a wake succeeds
    /// or the agent starts another turn.
    public let wakeRefusal: String?
    public init(id: String, parentID: String?, title: String, status: SessionStatus,
                workflow: SessionWorkflow?, background: Bool = false, recoveryError: Bool = false,
                wakeRefusal: String? = nil) {
        self.id = id; self.parentID = parentID; self.title = title; self.status = status
        self.workflow = workflow; self.background = background; self.recoveryError = recoveryError
        self.wakeRefusal = wakeRefusal
    }
}

public struct SessionWorkEntry: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable { case working, waiting, blocked, decision, paused, verified, cancelled, idle }
    public let id: String
    public let title: String
    public let identity: String
    public let kind: Kind
    public let label: String
    public let detail: String
    public let background: Bool
    public let job: WorkitJobSummary?
    public let managed: Bool
    public let phase: WorkitJobSummary.Phase?
    public let focusLane: SessionFocusLane?
    public let waitingForWorkit: Bool
    public let checkDueAt: Date?
    public let checkIsDue: Bool
    /// Set only while Workit owns the wait: its scheduled wake could not reach
    /// the agent, so nothing will resume this session on its own.
    public let wakeRefusal: String?
    public var needsAttention: Bool { kind == .blocked || kind == .decision }

    init(node: SessionWorkNode, job: WorkitJobSummary?, observedAt: Date? = nil) {
        id = node.id; title = node.title; background = node.background; managed = node.workflow != nil
        identity = node.workflow.map { "\($0.owner):\($0.jobID)" } ?? "session:\(node.id)"
        self.job = job
        phase = job?.phase
        let nextFocusLane: SessionFocusLane?
        if node.recoveryError {
            nextFocusLane = .act
        } else if let attention = job?.attention {
            nextFocusLane = .init(rawValue: attention.rawValue)
        } else if let job {
            switch job.group {
            case .needsYou: nextFocusLane = .act
            case .paused, .verified, .cancelled: nextFocusLane = .settled
            case .working, .waiting: nextFocusLane = .watch
            }
        } else {
            nextFocusLane = .forSessionStatus(node.status)
        }
        // Terminal status is normally newer than the saved overview. Never let stale
        // work metadata turn an explicit human request or a finished run into
        // background work. An external Workit wait is the exception: CI/deployment
        // waits stay quiet even when their terminal still shows an old prompt.
        let quietExternalWait = job?.group == .waiting && nextFocusLane == .watch
        if node.status.isActivelyWorking, nextFocusLane != .act {
            focusLane = .watch
        } else {
            switch node.status {
            case .needInput, .asking, .review, .failed:
                focusLane = quietExternalWait ? .watch : .act
            case .completed, .closed:
                focusLane = nextFocusLane == .watch ? .settled : nextFocusLane
            default:
                focusLane = nextFocusLane
            }
        }
        var nextKind: Kind
        var nextLabel: String
        var nextDetail: String
        if node.recoveryError {
            nextKind = .blocked; nextLabel = "Recovery needed"; nextDetail = "The workflow journal could not be read. Inspect recovery before continuing."
        } else if let job, let display = job.display, let parsed = Kind(rawValue: display.kind), !display.label.isEmpty {
            nextKind = parsed; nextLabel = display.label; nextDetail = job.stopReason ?? job.detail
        } else if let workflow = node.workflow {
            nextDetail = job?.stopReason ?? job?.detail ?? workflow.detail
            switch workflow.state {
            case .working: nextKind = .working; nextLabel = "Working"
            case .waiting: nextKind = .waiting; nextLabel = "Waiting"
            case .needsYou: nextKind = .blocked; nextLabel = "Check job"
            case .paused: nextKind = .paused; nextLabel = "Paused"
            case .verified: nextKind = .verified; nextLabel = "Verified"
            case .cancelled: nextKind = .cancelled; nextLabel = "Cancelled"
            }
        } else {
            nextDetail = "Conversation status; no managed issue completion is recorded."
            switch node.status {
            case .executing, .subagents, .longRunningShell: nextKind = .working; nextLabel = "Working"
            case .asking: nextKind = .decision; nextLabel = "Input requested"
            case .failed: nextKind = .blocked; nextLabel = "Session failed"
            default: nextKind = .idle; nextLabel = "Idle"
            }
        }
        if let phase = job?.phase, phase == .merged {
            nextLabel = (job?.progress.total ?? 0) > 0
                ? "Merged · \(job?.progress.passed ?? 0)/\(job?.progress.total ?? 0) AC"
                : "Merged"
        }
        // Owner workflow state describes unfinished delivery, not whether the
        // agent is executing a turn. Preserve explicit waits/holds/completion,
        // but do not show a saved "working" projection as current activity.
        if nextKind == .working, !node.status.isActivelyWorking {
            let activity: String
            switch node.status {
            case .needInput: nextKind = .idle; activity = "Waiting for input"
            case .asking: nextKind = .decision; activity = "Input requested"
            case .review: nextKind = .idle; activity = "Ready for review"
            case .failed: nextKind = .blocked; activity = "Session failed"
            case .completed, .closed: nextKind = .idle; activity = "Agent finished"
            default: nextKind = .idle; activity = "Idle"
            }
            nextLabel = job?.phase == .merged
                ? "\(activity) · \(nextLabel)" : "\(activity) · workflow unfinished"
        }
        kind = nextKind; label = nextLabel; detail = nextDetail
        waitingForWorkit = nextKind == .waiting && node.workflow?.owner == "workit"
            && [.idle, .needInput, .completed].contains(node.status)
            && (job == nil || ["waiting-ci", "waiting-deploy"].contains(job?.stage ?? ""))
        checkDueAt = waitingForWorkit ? job?.externalCheckDate : nil
        checkIsDue = checkDueAt.map { due in observedAt.map { due.isAtOrBefore($0) } ?? false } ?? false
        wakeRefusal = waitingForWorkit ? node.wakeRefusal : nil
    }
}

public struct SessionWorkSummary: Sendable, Equatable {
    public struct GroupStatus: Identifiable, Sendable, Equatable {
        public enum Category: Sendable, Equatable {
            case needsYou
            case phase(WorkitJobSummary.Phase)
            case kind(SessionWorkEntry.Kind)
        }

        public let category: Category
        public let count: Int

        public var id: String {
            switch category {
            case .needsYou: "needs-you"
            case .phase(let phase): "phase-\(phase.rawValue)"
            case .kind(let kind): "kind-\(kind.rawValue)"
            }
        }

        public var label: String {
            switch category {
            case .needsYou: "needs you"
            case .phase(let phase): phase.summaryLabel
            case .kind(let kind):
                switch kind {
                case .working: "working"
                case .waiting: "waiting"
                case .blocked: "blocked"
                case .decision: "need input"
                case .paused: "paused"
                case .verified: "verified"
                case .idle: "idle"
                case .cancelled: "cancelled"
                }
            }
        }
    }

    public let own: SessionWorkEntry
    public var descendants: [SessionWorkEntry] = []
    public var groupStatuses: [GroupStatus] {
        if descendants.contains(where: { $0.phase != nil }) {
            var entries: [GroupStatus] = []
            let needsYou = descendants.filter(\.needsAttention).count
            if needsYou > 0 { entries.append(.init(category: .needsYou, count: needsYou)) }
            let remaining = descendants.filter { !$0.needsAttention }
            for phase in WorkitJobSummary.Phase.allCases {
                let count = remaining.filter { $0.phase == phase }.count
                if count > 0 { entries.append(.init(category: .phase(phase), count: count)) }
            }
            let counts = Dictionary(grouping: remaining.filter { $0.phase == nil }, by: \.kind).mapValues(\.count)
            let kinds: [SessionWorkEntry.Kind] = [.working, .waiting, .blocked, .decision, .paused, .verified, .idle, .cancelled]
            entries.append(contentsOf: kinds.compactMap { kind in
                counts[kind].map { GroupStatus(category: .kind(kind), count: $0) }
            })
            return entries
        }
        let counts = Dictionary(grouping: descendants, by: \.kind).mapValues(\.count)
        let kinds: [SessionWorkEntry.Kind] = [.working, .waiting, .blocked, .decision, .paused, .verified, .idle, .cancelled]
        return kinds.compactMap { kind in
            counts[kind].map { GroupStatus(category: .kind(kind), count: $0) }
        }
    }
    public var groupLabel: String {
        groupStatuses.map { "\($0.count) \($0.label)" }.joined(separator: " · ")
    }
}

public enum SessionWorkTree {
    /// Evaluated once per relevant change by the store, never once per visible row.
    public static func summaries(nodes: [SessionWorkNode], overview: WorkitOverview?) -> [String: SessionWorkSummary] {
        let nodes = nodes.filter { $0.status != .closed }
        let byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let jobs = Dictionary((overview?.jobs ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let observedAt = WorkitJobSummary.date(overview?.generatedAt)
        var result: [String: SessionWorkSummary] = [:]
        for node in byID.values {
            let job = node.workflow.flatMap { workflow -> WorkitJobSummary? in
                guard workflow.owner == "workit", let value = jobs[workflow.jobID], value.sessionID == node.id,
                      value.revision >= workflow.revision else { return nil }
                return value
            }
            result[node.id] = SessionWorkSummary(own: SessionWorkEntry(node: node, job: job,
                observedAt: observedAt))
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
