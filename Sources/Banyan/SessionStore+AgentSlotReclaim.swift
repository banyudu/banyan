import BanyanCore
import Foundation

/// An idle terminal command keeps its reservation while nothing is waiting for
/// capacity: the cap is about demand, and a command that is not working is not
/// demand. When work *is* queued, though, a reservation held by a verified-idle
/// command is the only thing the queue can ever wait for — an idle CLI leaves
/// its slot when its process exits, and a fleet parked above the cap never
/// exits. So queued work reclaims the least recently used idle reservation.
///
/// Nothing is signalled and nothing is killed: the command keeps running, its
/// pane and scrollback stay attached, and it re-adopts a reservation through
/// `adoptObservedAgentActivity` as soon as it is active again. That keeps the
/// cap meaning "how much new work Banyan starts" rather than "how many live
/// sessions a user may keep".
extension SessionStore {
    func requestAgentSlotReclaimIfNeeded() {
        guard !isReclaimingAgentSlotForQueue,
              !agentAdmission.queuedIDs.isEmpty,
              agentAdmission.running.count >= maximumConcurrentAgents else { return }
        isReclaimingAgentSlotForQueue = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let yielded = await self.yieldIdleReservationToQueuedWork()
            self.isReclaimingAgentSlotForQueue = false
            // One reservation per released command: the release itself changes
            // the count, so re-read the queue and the budget before deciding
            // whether another idle command has to pay.
            if yielded { self.requestAgentSlotReclaimIfNeeded() }
        }
    }

    /// Oldest quiet command first, so the session a human just used is never
    /// the one that gives up its slot. Returns true when one was released.
    private func yieldIdleReservationToQueuedWork() async -> Bool {
        let now = Date()
        let candidates = terminalSessions.map { session in
            AgentSuspendCandidate(
                id: session.id,
                lastInteraction: session.lastFreezeInteractionAt,
                eligible: agentAdmission.running.contains(session.id) && isIdleYieldCandidate(session, now: now)
            )
        }
        for id in AgentDeepSuspend.leastRecentlyUsed(candidates) {
            guard let terminal = admissionTerminals[id], await paneHasBeenQuiet(terminal) else { continue }
            releaseAgentReservationForQueuedWork(id: id)
            return true
        }
        return false
    }

    /// Cheap, in-memory eligibility. The pane quiescence probe is deliberately
    /// not part of it: it costs a tmux round trip per candidate, and the LRU
    /// order means at most one is normally needed.
    private func isIdleYieldCandidate(_ terminal: TerminalSession, now: Date) -> Bool {
        guard !terminal.isImportedHistory, !terminal.isFrozen, !terminal.isSuspended,
              !terminal.isDeepSuspended, !terminal.isDeepResuming, !terminal.isDeepTerminating,
              terminal.suspendTicket == nil, terminal.freezeInputInFlight == 0,
              terminal.status.isCodingAgentIdle,
              terminal.admissionProviderIdentity != nil || terminal.admissionProcessIdentity != nil,
              !pendingAgentFreezeIDs.contains(terminal.id),
              now.timeIntervalSince(terminal.lastFreezeInteractionAt) >= AgentAdmissionController.idleYieldQuiescenceSeconds
        else { return false }
        return true
    }

    /// Output silence, not just a status label. A status that has not caught up
    /// with a just-started turn must not free capacity for another launch.
    private func paneHasBeenQuiet(_ terminal: TerminalSession) async -> Bool {
        let backend = terminal.tmuxBackend
        let name = terminal.tmuxSessionName
        let inspection = await Task.detached(priority: .utility) {
            backend.agentAdmissionPane(named: name)
        }.value
        guard case .present(let pane) = inspection, !pane.isDead, let lastActivityAt = pane.lastActivityAt else { return false }
        return Date().timeIntervalSince(lastActivityAt) >= AgentAdmissionController.idleYieldQuiescenceSeconds
    }

    private func releaseAgentReservationForQueuedWork(id: String) {
        guard let terminal = admissionTerminals[id], agentAdmission.running.contains(id) else { return }
        // Keep the recorded provider identity as provenance: the command is
        // still running and re-adopts this reservation when it works again.
        terminal.admissionInspectionError = nil
        terminal.touch()
        agentAdmission.release(id)
    }

    /// A released reservation comes back the moment the command is observed
    /// working, so the budget reflects work that is actually running.
    func adoptObservedAgentActivity(id: String) {
        guard let terminal = admissionTerminals[id], !terminal.status.isCodingAgentIdle else { return }
        adoptAgentReservation(id: id)
    }

    /// Typing into an idle command starts work in it. Adopt before the
    /// keystroke lands rather than after the supervisor notices, so the count
    /// never under-reports work the user just kicked off.
    func adoptAgentReservationForInteraction(id: String) {
        adoptAgentReservation(id: id)
    }

    private func adoptAgentReservation(id: String) {
        guard let terminal = admissionTerminals[id], !agentAdmission.running.contains(id),
              !terminal.isImportedHistory, !terminal.isFrozen, !terminal.isSuspended,
              !terminal.isDeepSuspended, !terminal.isDeepResuming, !terminal.isDeepTerminating,
              terminal.suspendTicket == nil, terminal.status != .closed,
              terminal.agentProvider != nil || !terminal.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              terminal.admissionProviderIdentity != nil || terminal.admissionProcessIdentity != nil
        else { return }
        agentAdmission.adopt(id)
        // Reconciles a stale identity into a release, so adopting a command
        // whose agent already exited cannot inflate the budget.
        reconcileAgentAdmission(id: id)
    }
}
