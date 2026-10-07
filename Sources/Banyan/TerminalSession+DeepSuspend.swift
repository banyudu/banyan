import BanyanCore
import Foundation

extension TerminalSession {
    func cancelDeepLifecycle() {
        deepLifecycleGeneration = UUID()
        deepResumeTask?.cancel()
        deepResumeTask = nil
        deepTerminationSource?.cancel()
        deepTerminationSource = nil
        pendingDeepResume = false
    }

    func restoreDeepSuspendTicket() {
        guard !hasLoadedDeepSuspendTicket, suspendTicket == nil else { return }
        applyDeepSuspendJournal(tmuxBackend.readSuspendJournal(named: tmuxSessionName),
            pane: tmuxBackend.primaryPaneSnapshot(named: tmuxSessionName))
    }

    func applyDeepSuspendJournal(_ state: AgentSuspendJournalState, pane: TmuxPaneSnapshot?) {
        guard status != .closed, !hasLoadedDeepSuspendTicket, suspendTicket == nil else { return }
        let ticket: AgentSuspendTicket
        switch state {
        case .absent:
            hasLoadedDeepSuspendTicket = true
            if deepRecoveryIsUncertain { isDeepSuspended = false; deepSuspendError = nil }
            deepRecoveryIsUncertain = false
            return
        case .unavailable(let reason):
            deepRecoveryIsUncertain = true
            isDeepSuspended = true
            deepSuspendError = reason
            return
        case .valid(let recovered):
            ticket = recovered
        }
        guard let pane, pane.paneID == ticket.paneID,
              AgentProcessSample.read(pid: Int32(pane.rootPID))?.identity == ticket.root else {
            deepRecoveryIsUncertain = true
            isDeepSuspended = true
            deepSuspendError = "Recovery journal does not match the pane identity; input blocked"
            return
        }
        hasLoadedDeepSuspendTicket = true
        deepRecoveryIsUncertain = false
        deepSuspendError = nil
        suspendTicket = ticket
        isDeepSuspended = true
        isDeepTerminating = ticket.phase == .terminating && deepProcessPresence(ticket.agent) != .exited
        if isDeepTerminating { watchDeepTermination(ticket) }
        else if ticket.phase == .terminating { completeDeepTermination(ticket) }
    }

    func watchDeepTermination(_ ticket: AgentSuspendTicket) {
        guard deepTerminationSource == nil else { return }
        let generation = deepLifecycleGeneration
        let source = DispatchSource.makeProcessSource(identifier: ticket.agent.pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.status != .closed, self.deepLifecycleGeneration == generation else { return }
                self.completeDeepTermination(ticket)
            }
        }
        deepTerminationSource = source
        source.resume()
        if deepProcessPresence(ticket.agent) == .exited { completeDeepTermination(ticket) }
    }

    func completeDeepTermination(_ original: AgentSuspendTicket) {
        guard status != .closed, suspendTicket?.agent == original.agent, suspendTicket?.phase == .terminating,
              let pane = tmuxBackend.primaryPaneSnapshot(named: tmuxSessionName), pane.paneID == original.paneID,
              AgentProcessSample.read(pid: Int32(pane.rootPID))?.identity == original.root,
              deepProcessPresence(original.agent) == .exited else { return }
        deepTerminationSource?.cancel()
        deepTerminationSource = nil
        var ticket = original
        ticket.phase = .suspended
        suspendTicket = ticket
        isDeepSuspended = true
        isDeepTerminating = false
        deepSuspendError = nil
        do { try tmuxBackend.writeSuspendTicket(ticket, named: tmuxSessionName) }
        catch { deepSuspendError = error.localizedDescription }
        telemetry.recordDuration("agent.deep_suspend", durationMS: 0, sessionID: id,
            detail: "provider=\(ticket.disk.provider.rawValue) rss_released=\(ticket.residentBytes)")
        touch()
        if pendingDeepResume {
            let generation = deepLifecycleGeneration
            // The exit event precedes the host's waitpid/TTY handback. Bound the
            // readiness wait rather than racing command text into a dying job.
            deepResumeTask = Task { [weak self] in
                for delay in [50, 100, 200, 400, 800] {
                    try? await Task.sleep(for: .milliseconds(delay))
                    guard let self, !Task.isCancelled, self.deepLifecycleGeneration == generation, self.status != .closed else { return }
                    do { try self.beginDeepResume(); return }
                    catch { self.deepSuspendError = error.localizedDescription }
                }
            }
        }
    }

    /// Called synchronously before focus/attach/input. Input is refused while
    /// startup is pending so it can never land at the shell prompt.
    func beginDeepResume() throws {
        guard status != .closed else { throw AgentFreezeError.unsafe("Closed session cannot resume an agent") }
        freezeGeneration = UUID()
        lastFreezeInteractionAt = Date()
        restoreDeepSuspendTicket()
        guard !deepRecoveryIsUncertain else {
            throw AgentFreezeError.unsafe(deepSuspendError ?? "Recovery state is unknown; input blocked")
        }
        guard let ticket = suspendTicket else { return }
        guard let pane = tmuxBackend.primaryPaneSnapshot(named: tmuxSessionName), !pane.isDead,
              pane.paneID == ticket.paneID, Int32(pane.rootPID) == ticket.root.pid,
              AgentProcessSample.read(pid: ticket.root.pid)?.identity == ticket.root else {
            throw AgentFreezeError.unsafe("Suspended pane identity changed; recovery retained")
        }
        if isDeepTerminating, deepProcessPresence(ticket.agent) == .exited {
            // A one-shot exit notification may have met a transient tmux read
            // failure. Retry reconciles the observed exit instead of waiting
            // for a notification that has already fired.
            completeDeepTermination(ticket)
            if !isDeepTerminating { try beginDeepResume(); return }
        }
        if isDeepTerminating {
            pendingDeepResume = true
            return
        }
        guard !isDeepResuming else { return }
        if ticket.phase == .resuming {
            let rows = ProcessTable.snapshot().descendants(of: pane.rootPID)
            let shell = AgentProcessSample.read(pid: ticket.shell.pid)
            if !rows.contains(where: { $0.isSupportedAgentForFreezing }), shell?.identity == ticket.shell,
               shell?.foregroundGroupID == shell?.groupID {
                // An observed startup failure has returned to the known shell.
                // A still-starting/wrong agent keeps resuming provenance instead.
                var suspended = ticket
                suspended.phase = .suspended
                try tmuxBackend.writeSuspendTicket(suspended, named: tmuxSessionName)
                suspendTicket = suspended
                try beginDeepResume()
                return
            }
            isDeepResuming = true
            monitorDeepResume(ticket)
            return
        }
        guard let shell = AgentProcessSample.read(pid: ticket.shell.pid), shell.identity == ticket.shell,
              shell.parentPID == ticket.root.pid, shell.sessionID == ticket.root.pid,
              shell.foregroundGroupID == shell.groupID, !shell.isStopped,
              deepProcessPresence(ticket.agent) == .exited else {
            throw AgentFreezeError.unsafe("Suspended pane/shell changed or agent has not exited; recovery retained")
        }
        let samples = try AgentProcessFreezer.snapshot(rootPID: ticket.root.pid)
        let allowed = Set([ticket.root, ticket.shell] + ticket.survivors)
        guard samples.allSatisfy({ row in
            allowed.contains(row.identity) && row.sessionID == ticket.root.pid && row.userID == shell.userID
                && (row.identity == ticket.shell || row.identity == ticket.root || row.groupID != shell.groupID)
        }), !pane.isInMode else {
            throw AgentFreezeError.unsafe("Surviving shell is busy; automatic resume refused")
        }
        // Ctrl-C clears any unfinished shell line before inserting exact argv.
        guard let input = tmuxBackend as? any TmuxInputBackend else {
            throw AgentFreezeError.unsafe("Backend does not support same-pane recovery input")
        }
        var resuming = ticket
        resuming.phase = .resuming
        // A write failure leaves the earlier suspended recovery metadata intact.
        try tmuxBackend.writeSuspendTicket(resuming, named: tmuxSessionName)
        suspendTicket = resuming
        pendingDeepResume = false
        isDeepResuming = true
        isDeepSuspended = true
        deepSuspendError = nil
        // Journal before sending anything. An interrupted send is uncertain,
        // so reconcile startup rather than blindly issuing a second command.
        do {
            try input.sendKeys(paneID: ticket.paneID, keys: [.interrupt])
            try input.sendLiteral(paneID: ticket.paneID, text: ticket.resumeCommand)
            try input.sendKeys(paneID: ticket.paneID, keys: [.enter])
        } catch {
            deepSuspendError = error.localizedDescription
            monitorDeepResume(resuming)
            throw error
        }
        monitorDeepResume(resuming)
        touch()
    }

    private func monitorDeepResume(_ ticket: AgentSuspendTicket) {
        let generation = deepLifecycleGeneration
        deepResumeTask = Task { [weak self] in
            guard let self else { return }
            let started = Date()
            do {
                // A bounded startup wait is required: providers have no common
                // ready notification. Back off, then require exact disk identity.
                for delay in [100, 200, 400, 800, 1_600, 2_000, 2_000] {
                    try await Task.sleep(for: .milliseconds(delay))
                    guard self.status != .closed, self.deepLifecycleGeneration == generation,
                          self.suspendTicket?.agent == ticket.agent else { return }
                    let backend = self.tmuxBackend
                    let name = self.tmuxSessionName
                    let environment = self.environment
                    let recovered = await Task.detached(priority: .utility) {
                        guard let current = backend.primaryPaneSnapshot(named: name), current.paneID == ticket.paneID,
                              AgentProcessSample.read(pid: Int32(current.rootPID))?.identity == ticket.root else { return false }
                        let table = ProcessTable.snapshot()
                        let rows = table.descendants(of: current.rootPID)
                        guard let provider = rows.first(where: {
                            guard $0.pid != Int(ticket.agent.pid),
                                  let sample = AgentProcessSample.read(pid: Int32($0.pid)),
                                  sample.sessionID == ticket.root.pid, sample.foregroundGroupID == sample.groupID,
                                  !ticket.survivors.contains(sample.identity) else { return false }
                            return AgentDeepSuspend.confirmsRecovery(ticket.disk, process: $0)
                        }), let result = AgentSupervisor(backend: backend,
                            processTable: AgentDeepSuspend.foregroundTable(rows: rows, agentPID: provider.pid)).inspect(tmuxSessionName: name,
                            launchCommand: ticket.resumeCommand, currentStatus: .running, cwd: ticket.disk.cwd,
                            environment: environment, paneSnapshot: current) else { return false }
                        let text = backend.captureVisibleText(paneID: current.paneID, lineLimit: 24)
                        return result.provider != nil && [.idle, .needInput, .asking].contains(result.status)
                            && AgentDeepSuspend.hasReadyPrompt(provider: ticket.disk.provider, text: text)
                    }.value
                    guard !Task.isCancelled, self.status != .closed, self.deepLifecycleGeneration == generation,
                          self.suspendTicket?.agent == ticket.agent else { return }
                    if recovered {
                        try self.tmuxBackend.writeSuspendTicket(nil, named: self.tmuxSessionName)
                        self.suspendTicket = nil
                        self.isDeepSuspended = false
                        self.isDeepResuming = false
                        self.status = .running
                        self.telemetry.recordDuration("agent.deep_resume", durationMS: Date().timeIntervalSince(started) * 1000,
                            sessionID: self.id, detail: "provider=\(ticket.disk.provider.rawValue)")
                        self.touch()
                        return
                    }
                }
                throw AgentFreezeError.unsafe("Provider readiness or exact session is unconfirmed; recovery retained. Retry Resume to reconcile startup, or inspect the pane.")
            } catch {
                guard !Task.isCancelled, self.status != .closed, self.deepLifecycleGeneration == generation,
                      self.suspendTicket?.agent == ticket.agent else { return }
                self.isDeepResuming = false
                // Keep resuming provenance: a slow correct process may still
                // become ready. Retry/relaunch reconciles it without reinjection.
                self.deepSuspendError = error.localizedDescription
                self.touch()
            }
        }
    }
}
