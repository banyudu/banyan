import BanyanCore
import Foundation

extension SessionStore {
    var workflowJournal: SessionWorkflowJournal {
        SessionWorkflowJournal(directory: BanyanDataDirectory.url(
            for: "Banyan/workflows", environment: host.environment, homeDirectory: host.homeDirectory))
    }

    func restoreWorkflows() {
        for session in sessions {
            do { session.workflow = try workflowJournal.load(id: session.id) }
            catch { session.workflowRecoveryError = error.localizedDescription }
            retainManagedNativeObservation(session)
        }
    }

    func setWorkflow(id: String, workflow: SessionWorkflow) throws {
        guard let session = sessions.first(where: { $0.id == id }), !session.isImportedHistory else {
            throw ControlError.notFound(id)
        }
        guard session.workflowRecoveryError == nil else { throw WorkflowError.refused("workflow journal is unreadable") }
        let next = try session.workflow?.replacing(workflow) ?? workflow
        if next != session.workflow {
            try workflowJournal.save(next, id: id)
            session.workflow = next
        }
        retainManagedNativeObservation(session)
        pauseCloseProjectionDidChange(id: id)
    }

    var verifiedWorkflowSessionIDs: [String] {
        sessions.filter { SessionWorkflowPolicy.shouldCloseVerified(workflow: $0.workflow, status: $0.status) }.map(\.id)
    }

    /// Explicit inspection-based recovery, separate from automatic retries.
    func resolveWorkflowWake(id: String, jobID: String, revision: Int, wakeID: String, outcome: String, detail: String) throws {
        guard let session = sessions.first(where: { $0.id == id }), var workflow = session.workflow,
              workflow.jobID == jobID, workflow.revision == revision, workflow.wake?.id == wakeID,
              ["delivered", "not-delivered"].contains(outcome), !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkflowError.refused("matching job, revision, wake and inspected delivery outcome are required")
        }
        if outcome == "delivered" { workflow.wake?.status = .delivered }
        else { workflow.wake = nil }
        try workflowJournal.save(workflow, id: id)
        session.workflow = workflow
    }

    @discardableResult
    func closeVerifiedWorkflows() throws -> [String] {
        let ids = verifiedWorkflowSessionIDs
        for id in ids { try close(id: id) }
        return ids
    }

    func wakeWorkflow(id: String, jobID: String, revision: Int, wakeID: String, text: String, coordination: Bool = false) async throws {
        guard !wakeID.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= 64 * 1024,
              let session = sessions.first(where: { $0.id == id }),
              let workflow = try messageWorkflow(session, coordination: coordination) else { throw WorkflowError.refused("managed session, wakeID and bounded text are required") }
        guard session.status != .closed, !coordination || (session.workflow?.state.permitsWake != false) else {
            throw WorkflowError.refused("session is closed or its issue workflow is held")
        }
        guard try workflow.shouldDeliver(jobID: jobID, revision: revision, wakeID: wakeID) else { return }
        guard !session.isSuspended, !session.isFrozen,
              !session.isDeepSuspended, !session.isDeepResuming, session.agentLaunchQueue?.cancelled != true,
              session.workflowRecoveryError == nil else { throw WorkflowError.refused("session is closed, parked, frozen or unavailable") }

        // Native Codex rows already expose a guarded turn API.
        if let native = session as? CodexSession {
            guard !native.isSending, native.state.activeTurnID == nil, !native.state.needsAttention,
                  native.state.runtime.type == "idle", native.state.connection == .subscribed,
                  native.draft.isEmpty else { throw WorkflowError.refused("native session is busy or needs human input") }
            try recordWorkflowWake(session, workflow: workflow, id: wakeID, status: .pending, coordination: coordination)
            let pending = try messageWorkflow(session, coordination: coordination)
            var submitted = false
            do {
                _ = try await native.coordinator.startTurn(sessionID: id, input: [
                    .object(["type": .string("text"), "text": .string(text)])
                ], authorization: {
                    guard session.status != .closed, !session.isSuspended, !session.isFrozen, !session.isDeepSuspended,
                          !native.isSending, native.draft.isEmpty, !native.state.needsAttention,
                          session.workflowRecoveryError == nil,
                          (!coordination || session.workflow?.state.permitsWake != false),
                          try self.messageWorkflow(session, coordination: coordination) == pending else {
                        throw WorkflowError.refused("session or authorization changed before native delivery")
                    }
                }, willSubmit: { submitted = true })
                try finishWorkflowWake(session, id: wakeID, status: .delivered, coordination: coordination)
            } catch {
                try? finishWorkflowWake(session, id: wakeID, status: submitted ? .uncertain : .notDelivered, coordination: coordination)
                throw error
            }
            return
        }

        guard let terminal = session as? TerminalSession, terminal.agentProvider != nil,
              !terminal.deepRecoveryIsUncertain else { throw WorkflowError.refused("unsupported or uncertain agent session") }
        terminal.freezeInputInFlight += 1
        defer { terminal.freezeInputInFlight -= 1 }
        let backend = tmuxBackend
        let name = terminal.tmuxSessionName
        let pane = await Task.detached { backend.agentAdmissionPane(named: name) }.value
        guard (!coordination || terminal.workflow?.state.permitsWake != false), try messageWorkflow(terminal, coordination: coordination) == workflow, !terminal.isSuspended,
              !terminal.isFrozen, !terminal.isDeepSuspended else { throw WorkflowError.refused("session changed during wake preparation") }

        switch pane {
        case .unknown:
            throw WorkflowError.refused("cannot establish pane identity")
        case .absent:
            try await resumeWorkflowConversation(terminal, workflow: workflow, wakeID: wakeID, text: text, observedPane: pane, coordination: coordination)
        case .present(let snapshot) where snapshot.isDead:
            try await resumeWorkflowConversation(terminal, workflow: workflow, wakeID: wakeID, text: text, observedPane: pane, coordination: coordination)
        case .present(let snapshot):
            let reading = try await readPaneOutput(id: id, lines: nil)
            let table = processTable
            let agentIdentity = await Task.detached {
                let agents = AgentDeepSuspend.deepestProviderProcesses(in: table.snapshot().descendants(of: snapshot.rootPID))
                guard agents.count == 1, let agent = agents.first else { return Optional<AgentProcessIdentity>.none }
                return AgentProcessSample.read(pid: Int32(agent.pid))?.identity
            }.value
            guard (!coordination || terminal.workflow?.state.permitsWake != false), try messageWorkflow(terminal, coordination: coordination) == workflow, terminal.status != .closed, reading.paneID == snapshot.paneID,
                  SessionWorkflowPolicy.canWake(status: reading.status, isSuspended: terminal.isSuspended,
                    isFrozen: terminal.isFrozen, isDeepSuspended: terminal.isDeepSuspended,
                    hasObservation: reading.observation != nil, isAgent: reading.observation?.provider != nil,
                    hasHumanPrompt: reading.prompt != nil,
                    hasEmptyInput: SessionWorkflowPolicy.hasEmptyInput(reading.visibleText)),
                  !snapshot.isInMode, let agentIdentity else { throw WorkflowError.refused("agent is busy, unobserved, or awaiting human input") }
            try recordWorkflowWake(terminal, workflow: workflow, id: wakeID, status: .pending, coordination: coordination)
            do {
                // Literal input goes only to the observed agent pane, never a
                // shell fallback. A change before sending any bytes is retryable.
                try await Task.detached {
                    guard let current = backend.primaryPaneSnapshot(named: name),
                          current.paneID == snapshot.paneID, current.rootPID == snapshot.rootPID,
                          current.lastActivityAt == snapshot.lastActivityAt, !current.isDead, !current.isInMode,
                          backend.captureVisibleText(paneID: snapshot.paneID, lineLimit: AgentSupervisor.captureLineLimit) == reading.visibleText,
                          AgentProcessSample.presence(of: agentIdentity) == .alive else {
                        throw WorkflowError.notDelivered("pane changed before input")
                    }
                    try backend.sendLiteral(paneID: snapshot.paneID, text: text)
                    try backend.sendKeys(paneID: snapshot.paneID, keys: [.enter])
                }.value
                noteInjection(id: id)
                try finishWorkflowWake(terminal, id: wakeID, status: .delivered, coordination: coordination)
            } catch {
                let status: SessionWorkflow.Wake.Status
                if case WorkflowError.notDelivered = error { status = .notDelivered }
                else { status = .uncertain }
                try? finishWorkflowWake(terminal, id: wakeID, status: status, coordination: coordination)
                throw error
            }
        }
    }

    private func resumeWorkflowConversation(_ terminal: TerminalSession, workflow: SessionWorkflow,
                                            wakeID: String, text: String, observedPane: AgentAdmissionPaneInspection, coordination: Bool) async throws {
        guard let provider = terminal.agentProvider, let sourceID = terminal.agentSessionID else {
            throw WorkflowError.refused("original conversation identity is unavailable; recovery requires inspection")
        }
        let history = deepSuspendHistory
        let cwd = terminal.cwd
        let candidates = await Task.detached {
            history.resumeCandidates(cwd: cwd, provider: provider.isOpencodeBacked ? .opencode : provider, maxFilesScanned: 20_000)
        }.value
        guard (!coordination || terminal.workflow?.state.permitsWake != false), try messageWorkflow(terminal, coordination: coordination) == workflow, !terminal.isSuspended, !terminal.isFrozen, !terminal.isDeepSuspended,
              candidates.contains(where: { $0.sourceID == sourceID &&
                  PathDisplayName.canonicalPath($0.cwd) == PathDisplayName.canonicalPath(cwd) &&
                  ($0.provider == provider || ($0.provider.isOpencodeBacked && provider.isOpencodeBacked)) }),
              let plan = SessionResumePolicy.plan(provider: provider, sourceID: sourceID, cwd: terminal.cwd,
                prompt: text, transcriptURL: nil, trimmed: false, history: deepSuspendHistory) else {
            throw WorkflowError.refused("original conversation identity is unavailable; recovery requires inspection")
        }
        let command = AgentSessionHistory.applyingCodexProfile(fromCommand: terminal.command, to: plan.command)
        let backend = tmuxBackend
        let name = terminal.tmuxSessionName
        let currentPane = await Task.detached { backend.agentAdmissionPane(named: name) }.value
        guard (!coordination || terminal.workflow?.state.permitsWake != false), try messageWorkflow(terminal, coordination: coordination) == workflow, terminal.status != .closed,
              !terminal.isSuspended, !terminal.isFrozen, !terminal.isDeepSuspended,
              !terminal.isDeepResuming, terminal.agentLaunchQueue?.cancelled != true,
              SessionWorkflowPolicy.canRecover(observed: observedPane, current: currentPane) else {
            throw WorkflowError.refused("pane or workflow changed during conversation recovery")
        }
        try recordWorkflowWake(terminal, workflow: workflow, id: wakeID, status: .pending, coordination: coordination)
        // Do not leave a deferred restart callback that could run after a later
        // pause/cancel or after another actor replaces the pane.
        guard terminal.requestAgentAdmission(queueIfBusy: false, retry: {}) else {
            try finishWorkflowWake(terminal, id: wakeID, status: .notDelivered, coordination: coordination)
            throw WorkflowError.notDelivered("agent admission is full; no recovery command was launched")
        }
        // This queues a native resume, never the original implementation prompt.
        terminal.command = command
        terminal.isProcessStarted = false
        terminal.isRestored = false
        if case .present = currentPane { terminal.restartBackingSession() }
        else { terminal.recoverFromMissingBackingSessionInBackground(command: command) }
        try finishWorkflowWake(terminal, id: wakeID, status: .delivered, coordination: coordination)
    }

    private func recordWorkflowWake(_ session: BanyanSession, workflow: SessionWorkflow,
                                    id: String, status: SessionWorkflow.Wake.Status, coordination: Bool) throws {
        var next = workflow
        next.wake = .init(id: id, status: status)
        try saveMessageWorkflow(next, session: session, coordination: coordination)
    }

    private func finishWorkflowWake(_ session: BanyanSession, id: String, status: SessionWorkflow.Wake.Status, coordination: Bool) throws {
        guard var next = try messageWorkflow(session, coordination: coordination), next.wake?.id == id else {
            throw WorkflowError.refused("workflow changed while delivering wake")
        }
        next.wake?.status = status
        try saveMessageWorkflow(next, session: session, coordination: coordination)
    }
}
