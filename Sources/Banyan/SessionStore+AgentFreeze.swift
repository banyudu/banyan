import AppKit
import BanyanCore
import Foundation
import IOKit.ps

private struct AgentFreezePreparation: Sendable {
    let ticket: AgentFreezeTicket
}

extension SessionStore {
    var agentFreezeThreshold: TimeInterval {
        let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue()
        let onBattery = info.flatMap { IOPSGetProvidingPowerSourceType($0)?.takeUnretainedValue() as String? } == kIOPSBatteryPowerValue
        return AgentInactivityPolicy.idleThreshold(minutes: agentFreezeIdleMinutes,
            background: NSApp?.isActive != true, onBattery: onBattery,
            sessionCount: terminalSessions.filter { $0.status != .closed }.count)
    }

    func resumeFrozenForInteraction(id: String?) {
        guard let terminal = terminalSessions.first(where: { $0.id == id }),
              terminal.status != .closed, !terminal.isImportedHistory else { return }
        // Invalidates pending freeze preparations even before a group is stopped.
        terminal.freezeGeneration = UUID()
        terminal.lastFreezeInteractionAt = Date()
        do { try terminal.beginDeepResume() }
        catch { terminal.deepSuspendError = error.localizedDescription }
        // A restored frontend may be selected before its asynchronous journal
        // read finishes. Consult tmux at that boundary instead of leaving an
        // unknown frozen agent stopped behind the selected terminal.
        guard terminal.isFrozen || terminal.frozenTicket != nil || terminal.isRestored else { return }
        do { try terminal.unfreezeAgent() }
        catch { terminal.freezeError = error.localizedDescription }
        resetSupervisorObservationBackoff(for: terminal.id)
    }

    func unfreezeAgent(id: String) throws {
        guard let terminal = sessions.first(where: { $0.id == id }) as? TerminalSession else {
            throw ControlError.badRequest("freeze/unfreeze requires a live terminal agent session")
        }
        try terminal.unfreezeAgent(recoverUserStop: true)
        resetSupervisorObservationBackoff(for: id)
    }

    func freezeAgent(id: String, automatic: Bool = false) async throws {
        guard !isAgentFreezeShuttingDown else { throw AgentFreezeError.unsafe("Application is shutting down") }
        guard let terminal = sessions.first(where: { $0.id == id }) as? TerminalSession,
              terminal.status != .closed, !terminal.isImportedHistory, !terminal.isSuspended, !terminal.isDeepSuspended else {
            throw ControlError.badRequest("freeze requires a live, unparked terminal agent session")
        }
        guard !terminal.isFrozen else { return }
        guard !pendingAgentFreezeIDs.contains(id), !isFreezeProtected(terminal) else {
            throw ControlError.badRequest("cannot freeze a selected, visible, busy, or interacting session")
        }
        pendingAgentFreezeIDs.insert(id)
        defer { pendingAgentFreezeIDs.remove(id) }
        let generation = terminal.freezeGeneration
        let knownIdentity = terminal.trackedPaneIdentity
        let backend = terminal.tmuxBackend
        let target = try paneTarget(id: id)
        let threshold = automatic ? agentFreezeThreshold : 2
        let lastInteraction = terminal.lastFreezeInteractionAt
        var preparedTicket: AgentFreezeTicket?
        do {
            let prepared = try await Task.detached(priority: .utility) {
                guard let pane = backend.primaryPaneSnapshot(named: target.tmuxSessionName),
                      !pane.isDead, !pane.hasAttachedClients, !pane.isInMode,
                      let activity = pane.lastActivityAt,
                      let identity = AgentProcessSample.read(pid: Int32(pane.rootPID))?.identity,
                      knownIdentity == nil || knownIdentity == identity else {
                    throw AgentFreezeError.unsafe("Pane is visible, missing, or its process identity changed")
                }
                let table = ProcessTable.snapshot()
                let agentPIDs = Set(table.descendants(of: pane.rootPID).filter { $0.isSupportedAgentForFreezing }.map { Int32($0.pid) })
                let first = try AgentProcessFreezer.snapshot(rootPID: identity.pid)
                let ticket = try AgentProcessFreezer.plan(root: identity, agentPIDs: agentPIDs, samples: first)
                let started = ProcessInfo.processInfo.systemUptime
                try await Task.sleep(for: .seconds(1))
                let second = try AgentProcessFreezer.snapshot(rootPID: identity.pid)
                let secondPlan = try AgentProcessFreezer.plan(root: identity, agentPIDs: agentPIDs, samples: second)
                guard Set(ticket.members) == Set(secondPlan.members), ticket.groups == secondPlan.groups,
                      AgentProcessFreezer.isQuiet(first, second, ticket: ticket,
                          elapsed: ProcessInfo.processInfo.systemUptime - started),
                      let fresh = backend.primaryPaneSnapshot(named: target.tmuxSessionName),
                      fresh.paneID == pane.paneID, fresh.rootPID == pane.rootPID,
                      fresh.lastActivityAt == activity, !fresh.isDead, !fresh.hasAttachedClients, !fresh.isInMode else {
                    throw AgentFreezeError.unsafe("Agent output, CPU, visibility, or process tree is active")
                }
                let result = AgentSupervisor(backend: backend, processTable: ProcessTable.snapshot()).inspect(
                    tmuxSessionName: target.tmuxSessionName, launchCommand: target.command,
                    currentStatus: target.status, cwd: target.cwd, sessionStartedAt: target.createdAt,
                    environment: target.environment, paneSnapshot: fresh)
                guard let result, result.provider != nil,
                      AgentInactivityPolicy.permitsSuspension(status: result.status, focused: false, visible: false,
                          quietSeconds: Date().timeIntervalSince(max(activity, lastInteraction)), threshold: threshold) else {
                    throw AgentFreezeError.unsafe("Agent is mid-turn or has not been quiet long enough")
                }
                try backend.writeFreezeTicket(ticket, named: target.tmuxSessionName)
                do {
                    // A journal subprocess can be delayed. Recheck output,
                    // clients and CPU after it completes, still off the UI actor.
                    let finalSamples = try AgentProcessFreezer.snapshot(rootPID: identity.pid)
                    guard let finalPane = backend.primaryPaneSnapshot(named: target.tmuxSessionName),
                          finalPane.paneID == pane.paneID, finalPane.rootPID == pane.rootPID,
                          finalPane.lastActivityAt == activity, !finalPane.hasAttachedClients,
                          !finalPane.isDead, !finalPane.isInMode,
                          AgentProcessFreezer.isQuiet(first, finalSamples, ticket: ticket,
                              elapsed: ProcessInfo.processInfo.systemUptime - started) else {
                        throw AgentFreezeError.unsafe("Session became active while recording its freeze ticket")
                    }
                    return AgentFreezePreparation(ticket: ticket)
                } catch {
                    if backend.freezeTicket(named: target.tmuxSessionName) == ticket {
                        try backend.writeFreezeTicket(nil, named: target.tmuxSessionName)
                    }
                    throw error
                }
            }.value
            preparedTicket = prepared.ticket
            // No await between the final focus/input guard and STOP. The UI and
            // control API serialize interaction with this commit on the main actor.
            guard sessions.contains(where: { $0 === terminal }), terminal.freezeGeneration == generation,
                  !isAgentFreezeShuttingDown, !isFreezeProtected(terminal), !automatic || autoFreezeAgents else {
                throw AgentFreezeError.unsafe("Session changed or became visible during freeze preparation")
            }
            terminal.frozenTicket = prepared.ticket
            terminal.isFrozen = true
            do { try AgentProcessFreezer.freeze(prepared.ticket) }
            catch {
                try terminal.unfreezeAgent()
                throw error
            }
            terminal.trackedPaneIdentity = prepared.ticket.root
            terminal.isFrozen = true
            terminal.freezeError = nil
            terminal.touch()
        } catch {
            if let preparedTicket, terminal.frozenTicket != preparedTicket {
                try await Task.detached(priority: .utility) {
                    if backend.freezeTicket(named: target.tmuxSessionName) == preparedTicket {
                        try backend.writeFreezeTicket(nil, named: target.tmuxSessionName)
                    }
                }.value
            }
            if !automatic { terminal.freezeError = error.localizedDescription }
            throw error
        }
    }

    private func isFreezeProtected(_ terminal: TerminalSession) -> Bool {
        terminal.id == selectedSessionID || terminal.id == selection.selectedSessionID
            || terminal.freezeInputInFlight > 0 || terminal.status == .closed || terminal.isSuspended
            || ![.idle, .needInput].contains(terminal.status)
    }

    /// The existing supervisor owns wakeups. Only eligible sessions incur libproc
    /// CPU probes, at an adaptive interval; output/focus/input cancel preparation.
    func runAutoFreezePassIfNeeded(now: Date = Date()) {
        guard autoFreezeAgents, !isAgentFreezeShuttingDown, !isAutoFreezeRunning, now >= nextAutoFreezeProbeAt else { return }
        let threshold = agentFreezeThreshold
        nextAutoFreezeProbeAt = now.addingTimeInterval(AgentInactivityPolicy.probeInterval(threshold: threshold))
        let ids = terminalSessions.filter {
            !$0.isFrozen && !isFreezeProtected($0)
                && now.timeIntervalSince($0.lastFreezeInteractionAt) >= threshold
        }.map(\.id)
        guard !ids.isEmpty else { return }
        isAutoFreezeRunning = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isAutoFreezeRunning = false }
            for id in ids {
                guard self.autoFreezeAgents else { return }
                try? await self.freezeAgent(id: id, automatic: true)
            }
        }
    }

    func resumeAllFrozenAgents() {
        for session in terminalSessions where session.isFrozen || session.frozenTicket != nil || session.isRestored {
            do {
                try session.unfreezeAgent()
                if !isAgentFreezeShuttingDown { resetSupervisorObservationBackoff(for: session.id) }
            }
            catch { session.freezeError = error.localizedDescription }
        }
    }

    func prepareForAgentFreezeShutdown() {
        isAgentFreezeShuttingDown = true
        for session in terminalSessions {
            session.freezeGeneration = UUID()
            session.cancelDeepLifecycle()
        }
        resumeAllFrozenAgents()
    }

    /// Existing supervisor wakeups reconcile external CONT/kill/attach events.
    /// Native selection and control input resume synchronously without this wait.
    func reconcileFrozenAgents() {
        guard !isFrozenReconciliationRunning else { return }
        let targets = terminalSessions.compactMap { session -> (String, String, AgentFreezeTicket)? in
            guard session.isFrozen, let ticket = session.frozenTicket else { return nil }
            return (session.id, session.tmuxSessionName, ticket)
        }
        guard !targets.isEmpty else { return }
        isFrozenReconciliationRunning = true
        let backend = tmuxBackend
        Task.detached(priority: .utility) { [weak self] in
            let panes = backend.primaryPaneSnapshots(named: Set(targets.map { $0.1 }))
            let resume = targets.filter { target in
                guard let pane = panes[target.1], !pane.isDead, !pane.hasAttachedClients else { return true }
                return target.2.members.contains { identity in
                    guard let row = AgentProcessSample.read(pid: identity.pid) else { return true }
                    return row.identity != identity || !row.isStopped
                }
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                defer { self.isFrozenReconciliationRunning = false }
                for (id, _, ticket) in resume {
                    guard let session = self.terminalSessions.first(where: { $0.id == id }),
                          session.frozenTicket == ticket else { continue }
                    do {
                        try session.unfreezeAgent()
                        self.resetSupervisorObservationBackoff(for: id)
                    }
                    catch { session.freezeError = error.localizedDescription }
                }
            }
        }
    }
}
