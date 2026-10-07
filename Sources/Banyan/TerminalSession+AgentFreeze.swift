import BanyanCore
import Foundation

extension TerminalSession {
    func prepareFrozenAgentForTeardown() throws {
        if let ticket = frozenTicket ?? tmuxBackend.freezeTicket(named: tmuxSessionName) {
            try AgentProcessFreezer.terminate(ticket)
            try unfreezeAgent()
        }
    }

    func trackPaneIdentityIfNeeded() {
        guard trackedPaneIdentity == nil,
              let pane = tmuxBackend.primaryPaneSnapshot(named: tmuxSessionName),
              let identity = AgentProcessSample.read(pid: Int32(pane.rootPID))?.identity else { return }
        trackedPaneIdentity = identity
        if let ticket = tmuxBackend.freezeTicket(named: tmuxSessionName), ticket.root == identity {
            frozenTicket = ticket
            isFrozen = true
        }
    }

    /// Synchronous at the interaction boundary: CONT precedes PTY input/attach.
    func unfreezeAgent(recoverUserStop: Bool = false) throws {
        freezeGeneration = UUID()
        lastFreezeInteractionAt = Date()
        let ticket = frozenTicket ?? tmuxBackend.freezeTicket(named: tmuxSessionName)
        guard let ticket else {
            if recoverUserStop { try resumeUserStoppedGroups() }
            return
        }
        do {
            try AgentProcessFreezer.unfreeze(ticket)
            if tmuxBackend.hasSession(named: tmuxSessionName) {
                try tmuxBackend.writeFreezeTicket(nil, named: tmuxSessionName)
            }
            frozenTicket = nil
            isFrozen = false
            freezeError = nil
            touch()
        } catch {
            freezeError = error.localizedDescription
            throw error
        }
    }

    /// Explicit recovery for Ctrl-Z/TSTP (or an external STOP). The host never
    /// auto-CONTs a child, so it cannot race with Banyan's owned STOP journal.
    private func resumeUserStoppedGroups() throws {
        guard let pane = tmuxBackend.primaryPaneSnapshot(named: tmuxSessionName), !pane.isDead,
              let root = AgentProcessSample.read(pid: Int32(pane.rootPID))?.identity,
              trackedPaneIdentity == nil || trackedPaneIdentity == root else {
            throw AgentFreezeError.unsafe("Pane process identity changed before stopped-job recovery")
        }
        let table = ProcessTable.snapshot().descendants(of: pane.rootPID)
        let isHosted = table.contains { $0.pid == pane.rootPID && $0.isBanyanProcessHost }
        let pids = Set(table.filter {
            isHosted ? $0.parentPID == pane.rootPID : $0.isSupportedAgentForFreezing
        }.map { Int32($0.pid) })
        guard !pids.isEmpty else { return }
        let samples = try AgentProcessFreezer.snapshot(rootPID: root.pid)
        let ticket = try AgentProcessFreezer.plan(root: root, agentPIDs: pids, samples: samples)
        guard samples.contains(where: { $0.isStopped && ticket.members.contains($0.identity) }) else { return }
        try AgentProcessFreezer.unfreeze(ticket)
        freezeError = nil
    }
}
