import BanyanCore
import Foundation

extension SessionStore {
    var coordinationJournal: SessionCoordinationJournal {
        .init(directory: BanyanDataDirectory.url(for: "Banyan/coordination",
            environment: host.environment, homeDirectory: host.homeDirectory))
    }

    func messageWorkflow(_ session: BanyanSession, coordination: Bool) throws -> SessionWorkflow? {
        coordination ? try coordinationJournal.bindings.load(id: session.id) : session.workflow
    }

    func saveMessageWorkflow(_ workflow: SessionWorkflow, session: BanyanSession, coordination: Bool) throws {
        if coordination { try coordinationJournal.bindings.save(workflow, id: session.id) }
        else {
            try workflowJournal.save(workflow, id: session.id)
            session.workflow = workflow
        }
    }

    func recordCoordinationIntervention(_ session: BanyanSession, text: String?) {
        guard let parent = session.parentSessionID else { return }
        do {
            guard let binding = try coordinationJournal.bindings.load(id: parent), binding.state == .working else { return }
            try coordinationJournal.appendIntervention(id: session.id, text: text ?? "User submitted terminal input; inspect the original conversation.")
        } catch {
            // A lost human intervention must prevent automated teardown.
            session.workflowRecoveryError = "Coordination input could not be recorded: \(error.localizedDescription)"
        }
    }

    func controlCoordination(_ body: CoordinationControlPayload) async throws -> [String: Any] {
        guard !body.groupID.isEmpty, body.groupID.utf8.count <= 128,
              let session = sessions.first(where: { $0.id == body.id }), !session.isImportedHistory else {
            throw WorkflowError.refused("an original session and bounded group ID are required")
        }
        if body.action == "observe" {
            guard let parent = body.parent, session.parentSessionID == parent,
                  try coordinationJournal.bindings.load(id: parent)?.jobID == body.groupID else {
                throw WorkflowError.refused("child does not belong to this coordinator")
            }
            return ["ok": true, "session": ["id": session.id, "parent": parent, "status": session.status.rawValue,
                "coordinationInterventions": try coordinationJournal.interventions(id: session.id).map {
                    ["id": $0.id, "at": $0.at, "text": $0.text]
                }]]
        }
        if body.action == "helper" {
            guard let parent = body.parent, session.parentSessionID == parent,
                  let workerID = body.worker, let run = body.runID, !run.isEmpty, let job = body.jobID,
                  let worker = sessions.first(where: { $0.id == workerID }), worker.parentSessionID == parent,
                  worker.workflow?.owner == "workit", worker.workflow?.jobID == job,
                  try coordinationJournal.bindings.load(id: parent)?.jobID == body.groupID else {
                throw WorkflowError.refused("verification helper must belong to the original group worker")
            }
            let binding = SessionWorkflow(owner: "workit-verifier", jobID: job + ":" + run, revision: 0,
                state: .working, detail: workerID)
            if let previous = try coordinationJournal.bindings.load(id: session.id), previous != binding {
                throw WorkflowError.refused("helper already has another owner")
            }
            try coordinationJournal.bindings.save(binding, id: session.id)
            return ["ok": true]
        }
        if body.action == "retire" || body.action == "retire-helper" {
            if body.action == "retire-helper" && (body.worker == nil || body.runID == nil) {
                throw WorkflowError.refused("helper retirement requires its original worker and run")
            }
            guard let parent = body.parent, let job = body.jobID, let revision = body.revision?.value else {
                throw WorkflowError.refused("retirement requires parent, job and revision")
            }
            try await retireCoordinatedSession(session, parent: parent, group: body.groupID, job: job,
                revision: revision, interventionID: body.interventionID ?? "",
                workerID: body.action == "retire-helper" ? body.worker : nil, runID: body.runID)
            return ["ok": true, "closed": session.id]
        }
        let journal = coordinationJournal.bindings
        let existing = try journal.load(id: session.id)
        if body.action == "bind" {
            guard session.status != .closed, session.agentProvider != nil || session is CodexSession else {
                throw WorkflowError.refused("coordinator must be an open agent conversation")
            }
            if let existing, existing.jobID != body.groupID, existing.state != .verified {
                throw WorkflowError.refused("session already coordinates another group")
            }
            if existing?.jobID != body.groupID {
                try journal.save(.init(owner: "workit-coordinator", jobID: body.groupID, revision: 0, state: .working), id: session.id)
            }
        } else {
            guard let existing, existing.jobID == body.groupID else { throw WorkflowError.refused("coordinator group does not match") }
            switch body.action {
            case "status": break
            case "deliver":
                guard let revision = body.revision?.value, let wake = body.wakeID, !wake.isEmpty, let text = body.text,
                      !text.isEmpty, text.utf8.count <= 64 * 1024 else {
                    throw WorkflowError.refused("delivery requires revision, wake ID and text")
                }
                // One monotonically numbered message at a time; older delivered
                // IDs cannot be replayed after a newer receipt replaces them.
                guard revision == existing.revision || revision == existing.revision + 1 else {
                    throw WorkflowError.refused("coordination message revision is stale or skipped")
                }
                if revision == existing.revision {
                    guard existing.detail == text, existing.wake == nil || existing.wake?.id == wake else {
                        throw WorkflowError.refused("message revision is already bound to different content or identity")
                    }
                }
                if revision > existing.revision {
                    guard existing.wake == nil || [.delivered, .notDelivered].contains(existing.wake!.status) else {
                        throw WorkflowError.refused("previous coordinator delivery needs reconciliation")
                    }
                    var next = try existing.replacing(.init(owner: existing.owner, jobID: existing.jobID,
                        revision: revision, state: existing.state, detail: text))
                    next.wake = .init(id: wake, status: .notDelivered)
                    try journal.save(next, id: session.id)
                }
                try await wakeWorkflow(id: session.id, jobID: body.groupID, revision: revision,
                    wakeID: wake, text: text, coordination: true)
            case "resolve":
                guard body.revision?.value == existing.revision, let wake = body.wakeID,
                      existing.wake?.id == wake, let detail = body.detail, !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let outcome = body.outcome, ["delivered", "not-delivered"].contains(outcome) else {
                    throw WorkflowError.refused("inspect matching revision and wake before resolving delivery")
                }
                var next = existing
                next.wake?.status = outcome == "delivered" ? .delivered : .notDelivered
                try journal.save(next, id: session.id)
            case "release":
                guard existing.wake == nil || [.delivered, .notDelivered].contains(existing.wake!.status) else {
                    throw WorkflowError.refused("unresolved coordinator delivery prevents release")
                }
                try journal.save(.init(owner: existing.owner, jobID: existing.jobID, revision: existing.revision,
                    state: .verified, wake: existing.wake), id: session.id)
            default: throw WorkflowError.refused("unknown coordination action")
            }
        }
        retainManagedNativeObservation(session)
        let binding = try journal.load(id: session.id)
        var result: [String: Any] = ["ok": true, "coordinationProtocol": 1, "revision": binding?.revision ?? 0,
            "groupID": body.groupID, "state": binding?.state.rawValue ?? ""]
        if let wake = binding?.wake { result["wake"] = ["id": wake.id, "status": wake.status.rawValue] }
        return result
    }

    private func retireCoordinatedSession(_ session: BanyanSession, parent: String, group: String,
                                          job: String, revision: Int, interventionID: String, workerID: String? = nil, runID: String? = nil) async throws {
        let evidenceSession: BanyanSession
        if let workerID {
            guard let runID, let worker = sessions.first(where: { $0.id == workerID }),
                  worker.parentSessionID == parent, worker.id != session.id,
                  let helper = try coordinationJournal.bindings.load(id: session.id),
                  helper.owner == "workit-verifier", helper.jobID == job + ":" + runID, helper.detail == workerID else {
                throw WorkflowError.refused("helper ownership does not match the accepted worker")
            }
            evidenceSession = worker
        } else {
            guard runID == nil else { throw WorkflowError.refused("helper requires its original worker") }
            evidenceSession = session
        }
        func validate() throws {
            guard evidenceSession.parentSessionID == parent,
                  try coordinationJournal.bindings.load(id: parent)?.jobID == group,
                  session.id != parent, session.parentSessionID == parent,
                  evidenceSession.workflow?.owner == "workit", evidenceSession.workflow?.jobID == job,
                  evidenceSession.workflow?.revision == revision, evidenceSession.workflow?.state == .verified,
                  evidenceSession.workflowRecoveryError == nil,
                  session.workflowRecoveryError == nil,
                  try workflowJournal.load(id: evidenceSession.id) == evidenceSession.workflow,
                  try (workerID != nil && session.status == .closed) || (coordinationJournal.interventions(id: session.id).last?.id ?? "") == interventionID,
                  !sessions.contains(where: { $0.parentSessionID == session.id && $0.status != .closed }) else {
                throw WorkflowError.refused("retirement requires the unchanged verified child and acknowledged user input")
            }
            guard session.status == .closed || (selectedSessionID != session.id &&
                ![.running, .executing, .subagents, .longRunningShell, .asking].contains(session.status) && !session.isSuspended && !session.isFrozen &&
                !session.isDeepSuspended && !session.isDeepResuming && !session.isDeepTerminating) else {
                throw WorkflowError.refused("selected or suspended children are retained")
            }
        }
        try validate()
        if session.status == .closed { return }
        if let native = session as? CodexSession {
            guard !native.isSending, native.state.activeTurnID == nil, !native.state.needsAttention,
                  native.state.runtime.type == "idle", native.state.connection == .subscribed, native.draft.isEmpty else {
                throw WorkflowError.refused("native child is active, unobserved or has a draft")
            }
        } else if let terminal = session as? TerminalSession {
            guard !terminal.deepRecoveryIsUncertain else { throw WorkflowError.refused("child recovery is uncertain") }
            terminal.freezeInputInFlight += 1
            defer { terminal.freezeInputInFlight -= 1 }
            let backend = tmuxBackend, name = terminal.tmuxSessionName
            let pane = await Task.detached { backend.agentAdmissionPane(named: name) }.value
            switch pane {
            case .unknown: throw WorkflowError.refused("child liveness is unknown")
            case .absent:
                guard SessionWorkflowPolicy.canRecover(observed: pane, current: backend.agentAdmissionPane(named: name)) else {
                    throw WorkflowError.refused("child pane appeared before retirement")
                }
            case .present(let snapshot) where snapshot.isDead:
                guard SessionWorkflowPolicy.canRecover(observed: pane, current: backend.agentAdmissionPane(named: name)) else {
                    throw WorkflowError.refused("child pane was replaced before retirement")
                }
            case .present(let snapshot):
                let reading = try await readPaneOutput(id: session.id, lines: nil)
                guard reading.paneID == snapshot.paneID, !snapshot.isInMode,
                      SessionWorkflowPolicy.canWake(status: reading.status, isSuspended: false, isFrozen: false,
                        isDeepSuspended: false, hasObservation: reading.observation != nil,
                        isAgent: reading.observation?.provider != nil, hasHumanPrompt: reading.prompt != nil,
                        hasEmptyInput: SessionWorkflowPolicy.hasEmptyInput(reading.visibleText)) else {
                    throw WorkflowError.refused("child is busy or awaiting user input")
                }
                guard let current = backend.primaryPaneSnapshot(named: name), current.paneID == snapshot.paneID,
                      current.rootPID == snapshot.rootPID, current.lastActivityAt == snapshot.lastActivityAt,
                      !current.isInMode, !current.isDead,
                      backend.captureVisibleText(paneID: snapshot.paneID, lineLimit: AgentSupervisor.captureLineLimit) == reading.visibleText else {
                    throw WorkflowError.refused("child changed before retirement")
                }
            }
            try validate()
        } else { throw WorkflowError.refused("unsupported child backend") }
        try validate()
        try close(id: session.id)
    }
}
