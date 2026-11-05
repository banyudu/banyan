import BanyanCore
import Foundation
import AppKit
import SwiftUI

extension SessionStore {
    // MARK: - Pane reading and input

    /// Snapshots the identity a pane operation needs, and refuses one for a
    /// session that is closed — a closed row has no pane to read or type into.
    func paneTarget(id: String) throws -> SessionPaneTarget {
        guard let found = sessions.first(where: { $0.id == id }) else {
            throw ControlError.notFound(id)
        }
        guard let session = found as? TerminalSession else {
            throw ControlError.conflict(
                code: "session_has_no_pane",
                message: "session '\(id)' is a \(found.backingSessionName) and has no terminal pane"
            )
        }
        guard session.status != .closed else {
            throw ControlError.conflict(code: "session_closed", message: "session '\(id)' is closed")
        }
        // An imported-history row reconstructs a session that already ended; it has
        // no pane behind it, so say that rather than fail later on a missing one.
        guard !session.isImportedHistory else {
            throw ControlError.conflict(
                code: "session_imported_history",
                message: "session '\(id)' is imported history and has no live pane"
            )
        }
        return SessionPaneTarget(
            id: session.id,
            tmuxSessionName: session.tmuxSessionName,
            command: session.command,
            status: session.status,
            cwd: session.cwd,
            createdAt: session.createdAt,
            environment: session.environment,
            isSuspended: session.isSuspended,
            isFrozen: session.isFrozen,
            isDeepSuspended: session.isDeepSuspended
        )
    }

    /// Folds a one-off pane reading back into the sidebar, exactly as a supervisor
    /// tick would, and tells the answer ledger what the pane is showing now.
    func absorb(_ reading: SessionPaneReading, for id: String) {
        answerLedger.note(sessionID: id, observedFootprint: reading.prompt?.footprint)
        guard let observation = reading.observation else { return }
        applySupervisorResults([observation])
    }

    func decideAnswer(id: String, request: AgentAnswerRequest, reading: SessionPaneReading) -> AgentAnswerDecision {
        answerLedger.decide(
            sessionID: id,
            request: request,
            observedStatus: reading.status,
            observedPrompt: reading.prompt
        )
    }

    /// Releases a footprint reserved for an answer that never reached the pane.
    func releaseConsumedAnswer(id: String) {
        answerLedger.forget(sessionID: id)
    }

    /// An injected keystroke changes the session's state within a beat, so drop
    /// whatever observation backoff the session had built up while it sat idle and
    /// let the next tick see it at the fast cadence.
    ///
    /// Deliberately does not observe right now: the agent has not reacted yet, so
    /// an immediate tick spends tmux subprocesses re-reading the state we just
    /// typed into.
    func noteInjection(id: String) {
        resetSupervisorObservationBackoff(for: id)
    }

    func sessionEvents(since: Int?) -> SessionEventBatch {
        sessionEventLog.batch(since: since)
    }

    /// Seed the supervisor's fingerprint when an on-demand decision card is
    /// opened, so a desktop resolution before the next tick is observable.
    func noteSlackObservedPrompt(sessionID: String, footprint: String) {
        let scope = slackPromptObservationScope()
        guard scope.ids.contains(sessionID), let token = scope.token else { return }
        if awayPromptActivationID != token {
            awayPromptActivationID = token
            awayPromptFootprints = slackDecisionJournal.observedPromptFootprints(allowed: codexRemote.policy.allowed)
        }
        awayPromptFootprints[sessionID] = footprint
    }

    /// A parked/frozen row can no longer accept remote input. Fence any
    /// off-main send first, then wake the card-maintenance stream if needed.
    func noteSlackSessionAvailability(_ session: BanyanSession) {
        guard sessions.contains(where: { $0 === session }) else { return }
        if session.status == .closed || session.isSuspended || session.isFrozen || session.isDeepSuspended {
            fenceSlackInput(for: session)
        }
        guard codexRemote.policy.enabled,
              slackDecisionJournal.observedSessionIDs(allowed: codexRemote.policy.allowed).contains(session.id) else { return }
        let event = sessionEventLog.append(sessionID: session.id, status: session.status, previousStatus: session.status)
        onSessionEvent?(event)
    }

    func fenceSlackInput(for session: BanyanSession) {
        guard sessions.contains(where: { $0 === session }) else { return }
        slackDecisionJournal.invalidateSession(session.id)
        slackFollowUpJournal.invalidateSession(session.id)
    }

    func recordStatusEvent(id: String, status: SessionStatus) {
        let previous = lastRecordedEventStatuses[id]
        guard previous != status else { return }
        lastRecordedEventStatuses[id] = status
        let event = sessionEventLog.append(sessionID: id, status: status, previousStatus: previous)
        onSessionEvent?(event)
    }

    func tick(id: String? = nil) throws {
        if let id {
            guard let session = sessions.first(where: { $0.id == id }) else {
                throw ControlError.notFound(id)
            }
            if session is PuckSession {
                syncPuckSessions()
            } else {
                runSupervisorTick(sessionID: id)
            }
        } else {
            runSupervisorTick(force: true)
            syncPuckSessions()
        }
        saveSessions()
    }
}
