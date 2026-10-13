import BanyanCore
import Foundation

/// A retained receipt makes projection-only retries honest and non-destructive.
@MainActor
final class PauseCloseAttempt {
    let session: BanyanSession
    let original: SessionWorkflow
    let command: String
    let terminalGeneration: UUID?
    let request: WorkitPauseRequest
    var acknowledgement: WorkitPausedJob?
    var invalidated = false
    var projectionWaiter: CheckedContinuation<Void, Never>?

    init(session: BanyanSession, workflow: SessionWorkflow) {
        self.session = session; original = workflow; command = session.command
        terminalGeneration = (session as? TerminalSession)?.admissionGeneration
        request = WorkitPauseRequest(jobID: workflow.jobID, expectedRevision: workflow.revision,
            sessionID: session.id, detail: "Paused by the operator from Banyan's close confirmation; issue remains unfinished.")
    }
}

extension SessionStore {
    var pendingCloseCanPause: Bool {
        guard let session = pendingCloseSession else { return false }
        return canPauseAndClose(session)
    }

    func canPauseAndClose(_ session: BanyanSession) -> Bool {
        guard !session.isImportedHistory, session.status != .closed, session.workflowRecoveryError == nil,
              let workflow = session.workflow else { return false }
        return workflow.owner == "workit" && !workflow.jobID.isEmpty && workflow.revision >= 0
            && !workflow.state.permitsClose
    }

    var pendingCloseIsPausing: Bool {
        pendingCloseSession.map { pauseCloseInFlightIDs.contains($0.id) } ?? false
    }

    var pendingCloseMessage: String {
        guard let session = pendingCloseSession else { return "" }
        var details: [String] = []
        if pendingCloseCanPause {
            details.append("Pause and Close leaves the issue unfinished and stops future automatic continuation. It does not verify or cancel the issue.")
            if session.closeEndsAgentWork {
                details.append("Closing may terminate the current coding agent.")
            }
        } else if session.workflow?.state.permitsClose == false || session.workflowRecoveryError != nil {
            details.append("This issue is unfinished or its workflow journal is unreadable. Use its workflow owner to resolve the hold before closing. Closing cannot mark an issue verified.")
        }
        details.append(session.closeConsequence)
        if pendingCloseHasOngoingAgent {
            details.append("Any running coding-agent process in that session will be terminated.")
        }
        if pendingCloseHasActiveChildren {
            details.append("Child sessions will be detached to the same level as this parent session.")
        }
        return details.joined(separator: " ")
    }

    func confirmPendingPauseAndClose() {
        guard let id = pendingCloseSession?.id, !pauseCloseInFlightIDs.contains(id) else { return }
        cancelPendingClose()
        startPauseAndClose(id: id)
    }

    func retryPauseAndClose() {
        guard let id = pauseCloseRetrySessionID else { return }
        pauseCloseError = nil
        startPauseAndClose(id: id)
    }

    private func startPauseAndClose(id: String) {
        guard pauseCloseUITaskIDs.insert(id).inserted else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { self.pauseCloseUITaskIDs.remove(id) }
            do { try await self.pauseAndClose(id: id) }
            catch {
                self.pauseCloseRetrySessionID = self.pauseCloseAttempts[id]?.acknowledgement != nil ? id : nil
                self.pauseCloseError = error.localizedDescription
            }
        }
    }

    /// This method never writes owner state or synthesizes a paused projection.
    func pauseAndClose(id: String) async throws {
        guard !pauseCloseInFlightIDs.contains(id) else {
            throw WorkflowError.refused("Pause and Close is already in progress. Wait for its result; the terminal remains open.")
        }
        guard let session = sessions.first(where: { $0.id == id }) else {
            throw WorkflowError.refused("The session changed. Reopen the close confirmation for the current session.")
        }
        let attempt: PauseCloseAttempt
        if let retained = pauseCloseAttempts[id], retained.acknowledgement != nil {
            attempt = retained
        } else {
            guard canPauseAndClose(session), let workflow = session.workflow else {
                throw WorkflowError.refused("Pause and Close requires an unfinished Workit-owned workflow with a readable journal. Resolve it with its workflow owner, then reopen the close confirmation.")
            }
            attempt = PauseCloseAttempt(session: session, workflow: workflow)
            pauseCloseAttempts[id] = attempt
        }
        pauseCloseInFlightIDs.insert(id)
        defer {
            pauseCloseInFlightIDs.remove(id)
            if attempt.acknowledgement == nil { pauseCloseAttempts[id] = nil }
        }
        do {
            try validatePauseCloseSession(attempt)
            if attempt.acknowledgement == nil {
                let result = try await workitPauseClient.pause(attempt.request)
                try result.validate(for: attempt.request)
                attempt.acknowledgement = result
            }
            try await awaitPauseProjection(attempt)
            // No suspension between the final check and the ordinary close.
            try validatePauseCloseSession(attempt)
            guard attempt.acknowledgement?.matches(session.workflow) == true else {
                throw WorkflowError.refused("The matching paused workflow is unconfirmed. Retry after Workit projects its pause.")
            }
            try Task.checkCancellation()
            pauseCloseInFlightIDs.remove(id)
            try close(id: id)
            pauseCloseAttempts[id] = nil
            pauseCloseRetrySessionID = nil
        } catch {
            if attempt.acknowledgement != nil {
                throw WorkflowError.refused("Workit acknowledged a durable pause, but the terminal remains open. \(error.localizedDescription) Retry Pause and Close to check the projection again without another owner pause. If the job changed, inspect it with Workit; Banyan will not clear a new hold or resume it.")
            }
            throw error
        }
    }

    private func validatePauseCloseSession(_ attempt: PauseCloseAttempt) throws {
        let session = attempt.session
        guard sessions.contains(where: { $0 === session }), session.status != .closed,
              session.command == attempt.command,
              (session as? TerminalSession)?.admissionGeneration == attempt.terminalGeneration,
              !attempt.invalidated else {
            throw WorkflowError.refused("The session or workflow changed during Pause and Close. Inspect the current job/session and reopen the close confirmation.")
        }
        guard session.workflowRecoveryError == nil else {
            throw WorkflowError.refused("The workflow journal is unreadable. Repair its readability and retry; the terminal remains open.")
        }
        do {
            guard try workflowJournal.load(id: session.id) == session.workflow else {
                throw WorkflowError.refused("journal differs from the current projection")
            }
        } catch {
            throw WorkflowError.refused("The workflow journal cannot confirm the current projection. Repair its readability or have Workit project the current job, then retry.")
        }
        guard session.workflow == attempt.original || attempt.acknowledgement?.matches(session.workflow) == true else {
            throw WorkflowError.refused("The job, revision, owner or session binding changed. Inspect the current Workit job before retrying; the terminal remains open.")
        }
    }

    private func awaitPauseProjection(_ attempt: PauseCloseAttempt) async throws {
        try validatePauseCloseSession(attempt)
        if attempt.acknowledgement?.matches(attempt.session.workflow) == true { return }
        // One deadline, woken by setWorkflow; no repeating timer or polling.
        let timeout = Task { [pauseCloseProjectionTimeout] in
            try? await Task.sleep(for: pauseCloseProjectionTimeout)
            if !Task.isCancelled {
                let waiter = attempt.projectionWaiter
                attempt.projectionWaiter = nil
                waiter?.resume()
            }
        }
        defer { timeout.cancel() }
        await withCheckedContinuation { attempt.projectionWaiter = $0 }
        try validatePauseCloseSession(attempt)
        guard attempt.acknowledgement?.matches(attempt.session.workflow) == true else {
            throw WorkflowError.refused("The matching paused projection has not arrived. Check Workit's Banyan control connection and retry after projection is repaired.")
        }
    }

    func pauseCloseProjectionDidChange(id: String) {
        guard let attempt = pauseCloseAttempts[id] else { return }
        let next = attempt.session.workflow
        if next != attempt.original {
            // The CLI can project before returning its receipt. Permit only a
            // candidate pause until the returned exact revision is available.
            if let ack = attempt.acknowledgement {
                if !ack.matches(next) { attempt.invalidated = true }
            } else if next?.owner != "workit" || next?.jobID != attempt.original.jobID
                || next?.state != .paused || (next?.revision ?? -1) <= attempt.original.revision {
                attempt.invalidated = true
            }
        }
        guard attempt.invalidated || attempt.acknowledgement?.matches(next) == true else { return }
        let waiter = attempt.projectionWaiter
        attempt.projectionWaiter = nil
        waiter?.resume()
    }
}
