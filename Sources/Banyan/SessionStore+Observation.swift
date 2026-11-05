import BanyanCore
import Foundation
import AppKit
import SwiftUI

extension SessionStore {
    func attach(_ session: BanyanSession) {
        session.autoRetryCodexFailures = autoRetryCodexFailures
        configureAgentAdmission(session)
        if let puck = session as? PuckSession {
            puck.onPendingChangedWithoutStatusTransition = { [weak self, weak puck] in
                guard let self, let puck, self.sessions.contains(where: { $0 === puck }),
                      puck.status != .closed, !puck.isSuspended,
                      self.slackPromptObservationScope().ids.contains(puck.id) else { return }
                let event = self.sessionEventLog.append(sessionID: puck.id, status: puck.status, previousStatus: puck.status)
                self.onSessionEvent?(event)
            }
        }
        if let terminal = session as? TerminalSession, terminal.isRestored, terminal.status != .closed {
            let backend = terminal.tmuxBackend
            let name = terminal.tmuxSessionName
            let generation = terminal.freezeGeneration
            Task.detached(priority: .utility) { [weak self, weak terminal] in
                let pane = backend.primaryPaneSnapshot(named: name)
                let identity = pane.flatMap { AgentProcessSample.read(pid: Int32($0.rootPID))?.identity }
                let ticket = backend.freezeTicket(named: name)
                let suspended = backend.readSuspendJournal(named: name)
                await MainActor.run { [weak self, weak terminal] in
                    guard let self, let terminal, terminal.status != .closed,
                          terminal.freezeGeneration == generation,
                          self.sessions.contains(where: { $0 === terminal }) else { return }
                    if terminal.trackedPaneIdentity == nil { terminal.trackedPaneIdentity = identity }
                    terminal.applyDeepSuspendJournal(suspended, pane: pane)
                    if terminal.isDeepSuspended, self.selectedSessionID == terminal.id {
                        self.resumeFrozenForInteraction(id: terminal.id)
                    }
                    if let ticket, ticket.root == identity {
                        terminal.frozenTicket = ticket
                        terminal.isFrozen = true
                        if !self.autoFreezeAgents || self.selectedSessionID == terminal.id {
                            self.resumeFrozenForInteraction(id: terminal.id)
                        }
                    }
                }
            }
        }
        var previousWorkNode = workNode(for: session)
        session.onHistoryRelevantChange = { [weak self, weak session] in
            guard let self, let session else { return }
            EnergyTrace.count("sidebar.historySignal", sessionID: session.id)
            let node = self.workNode(for: session)
            let previous = previousWorkNode
            previousWorkNode = node
            // Closed workflows still receive durable revision updates from their
            // owner. They are absent from the work tree, and workflow metadata
            // does not affect history ordering/filtering. Keep row observation
            // local instead of rebuilding the sidebar and fetching Workit again.
            let workflowOnly = node.status == previous.status && node.workflow != previous.workflow &&
                node.title == previous.title && node.parentID == previous.parentID &&
                node.recoveryError == previous.recoveryError
            if workflowOnly, node.status == .closed {
                EnergyTrace.count("sidebar.closedWorkflowSkipped", sessionID: session.id)
                return
            }
            if workflowOnly {
                self.workSummaryRevision &+= 1
                self.scheduleWorkOverviewRefresh()
                // State transitions also change menu/close permissions. A new
                // revision or detail at the same state only changes row data.
                if node.workflow?.state != previous.workflow?.state {
                    self.objectWillChange.send()
                }
                return
            }
            self.sidebarGroupsRevision &+= 1
            if node != previous {
                let workflowChanged = node.workflow != previous.workflow
                self.workSummaryRevision &+= 1
                // Titles, hierarchy and process status can change the list's
                // membership/order. Work details alone update row state instead.
                self.objectWillChange.send()
                if workflowChanged { self.scheduleWorkOverviewRefresh() }
            }
            self.noteSidebarHistoryChange(for: session)
        }
        var wasUnavailable = session.status == .closed || session.isSuspended || session.isFrozen || session.isDeepSuspended
        session.onDidChange = { [weak self, weak session] in
            if let session { EnergyTrace.count("session.didChange", sessionID: session.id) }
            if let self, let session {
                self.noteSidebarHistoryChange(for: session)
                let unavailable = session.status == .closed || session.isSuspended || session.isFrozen || session.isDeepSuspended
                if unavailable != wasUnavailable {
                    wasUnavailable = unavailable
                    self.noteSlackSessionAvailability(session)
                }
            }
            Task { @MainActor in
                // A native row may have been replaced by a terminal with the
                // same ID while this callback was queued. Persist the owner.
                guard let self, let session, self.sessions.contains(where: { $0 === session }) else { return }
                self.saveChangedSession(session)
                if self.selectedSessionID == session.id {
                    self.refreshSelectedContextInfo()
                }
            }
        }
        session.onOutput = { [weak self, weak session] text in
            guard let self, let session else { return }
            EnergyTrace.count("pty.output", sessionID: session.id)
            telemetry.noteSessionFirstOutput(sessionID: session.id)
            self.resetSupervisorObservationBackoff(for: session, invalidatesObservation: false)
            self.detectAttention(in: text, for: session)
            if let terminal = session as? TerminalSession, !terminal.isFrozen {
                terminal.freezeGeneration = UUID()
            }
        }
        session.onUserSubmittedInput = { [weak self, weak session] submittedInput in
            guard let self, let session else { return }
            self.recordCoordinationIntervention(session, text: submittedInput)
            session.codexAutoRetry.reset()
            if let terminal = session as? TerminalSession {
                terminal.codexRetryAutomaticTurn = false
                terminal.codexRetryWasExecuting = false
            }
            // A plain shell can become a coding-agent session without a picker
            // launch command. Its status/provider do not change until the next
            // supervisor observation, so user input must invalidate any quiet
            // session backoff that was built while the shell was idle.
            self.resetSupervisorObservationBackoff(for: session.id)
            // A submitted prompt is the other half of the turn-start signal: it
            // marks the session executing directly, so the supervisor never gets
            // to report the transition `applySupervisorResults` watches for.
            if SessionInputPolicy.submittedPromptTitle(from: submittedInput) != nil {
                self.scheduleAgentTitleImportIfNeeded(for: session)
            }
        }
        session.onStatusSignal = { [weak self, weak session] status in
            guard let self, let session, self.sessions.contains(where: { $0 === session }) else { return }
            if status == .closed {
                self.fenceSlackInput(for: session)
            }
            EnergyTrace.count("session.statusSignal", sessionID: session.id)
            self.resetSupervisorObservationBackoff(for: session.id)
            self.recordStatusEvent(id: session.id, status: status)
            // Puck asks are notified from routed watch events, not a status
            // inferred from a listing. Away delivery belongs to the notify peer.
            if !(session is PuckSession) {
                self.attentionNotifier.notifyIfNeeded(session: session, status: status)
            }
        }
        session.onProjectContextObserved = { [weak self, weak session] cwd, context in
            guard let self else { return }
            for sibling in self.sessions where sibling !== session && sibling.status != .closed && sibling.cwd == cwd {
                sibling.applyProjectContext(context)
            }
        }
        session.onProcessExit = { [weak self, weak session] _ in
            guard let self, let session = session as? TerminalSession, session.status != .closed else { return }
            EnergyTrace.count("session.processExit", sessionID: session.id)
            self.resetSupervisorObservationBackoff(for: session.id)
            if self.tmuxBackend.hasSession(named: session.tmuxSessionName) {
                session.detachTerminalClient()
            } else if session.coordinationRecoveryError == nil {
                try? self.close(id: session.id)
            }
        }
    }
}
