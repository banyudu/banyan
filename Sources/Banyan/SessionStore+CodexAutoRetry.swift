import BanyanCore
import Foundation

extension SessionStore {
    func noteCodexRetryInteraction(_ session: BanyanSession) {
        session.codexAutoRetry.cancel()
        if let terminal = session as? TerminalSession {
            terminal.codexRetryAutomaticTurn = false
            terminal.codexRetryWasExecuting = false
        }
    }

    func observeCodexRetry(_ session: TerminalSession, observation: SessionStatusObservation) {
        guard autoRetryCodexFailures, session.autoRetryCodexFailures, session.status != .closed,
              !session.isSuspended, !session.isFrozen, !session.isDeepSuspended,
              observation.provider == .codex else {
            if session.codexAutoRetry.attempts > 0 { session.codexAutoRetry.cancel() }
            return
        }
        if observation.status == .executing {
            if !session.codexRetryWasExecuting {
                session.codexRetryTurnGeneration = UUID()
                session.codexAutoRetry.beganTurn(automatic: session.codexRetryAutomaticTurn)
            }
            session.codexRetryWasExecuting = true
            return
        }
        guard observation.status == .needInput, let candidate = observation.codexRetryCandidate else {
            if session.codexRetryWasExecuting, observation.status == .needInput { session.codexAutoRetry.reset() }
            else if session.codexAutoRetry.attempts > 0 { session.codexAutoRetry.cancel() }
            session.codexRetryWasExecuting = false
            session.codexRetryAutomaticTurn = false
            return
        }
        session.codexRetryWasExecuting = false
        // A changed pane while waiting belongs to newer activity, not this retry.
        if let prior = session.codexRetryLastCandidate, prior != candidate,
           session.codexRetryStatus?.retryAt != nil {
            session.codexAutoRetry.cancel()
            return
        }
        session.codexRetryLastCandidate = candidate
        let generation = session.codexAutoRetry.generation
        let cancellation = session.codexAutoRetry.cancellation
        let threadID = session.agentSessionID
        let command = session.command
        let failureID = "\(session.codexRetryTurnGeneration):\(candidate.failureID)"
        session.codexAutoRetry.schedule(failureID: failureID, reason: candidate.prompt.reason) { [weak self, weak session] in
            guard let self, let session else { throw CancellationError() }
            // An idle CLI may have yielded its slot to other queued work.
            try await self.agentAdmission.acquire(session.id)
            try Task.checkCancellation()
            session.freezeInputInFlight += 1
            defer { session.freezeInputInFlight -= 1 }
            session.freezeGeneration = UUID()
            session.lastFreezeInteractionAt = Date()
            let target = try self.paneTarget(id: session.id)
            let backend = self.tmuxBackend
            let processes = self.processTable.snapshot()
            let fresh = await Task.detached(priority: .utility) {
                let supervisor = AgentSupervisor(backend: backend, processTable: processes)
                return supervisor.inspect(tmuxSessionName: target.tmuxSessionName, launchCommand: target.command,
                    currentStatus: target.status, cwd: target.cwd, sessionStartedAt: target.createdAt,
                    environment: target.environment)?.codexRetryCandidate
            }.value
            try Task.checkCancellation()
            guard self.autoRetryCodexFailures, session.autoRetryCodexFailures,
                  self.sessions.contains(where: { $0 === session }), session.codexAutoRetry.generation == generation,
                  session.agentSessionID == threadID, session.command == command,
                  session.status != .closed, !session.isSuspended, !session.isFrozen,
                  !session.isDeepSuspended, !session.isDeepResuming, !session.isDeepTerminating,
                  fresh == candidate,
                  AgentProcessSample.read(pid: candidate.root.pid)?.identity == candidate.root,
                  AgentProcessSample.read(pid: candidate.agent.pid)?.identity == candidate.agent else { throw CancellationError() }
            // One tmux command submits text and Enter together. Cancellation and
            // kernel identity checks also fence work queued behind other I/O.
            session.codexRetryAutomaticTurn = true
            try await backend.sendPrompt(paneID: candidate.paneID, text: CodexRetryPolicy.continuation) {
                cancellation.isCancelled
                    || AgentProcessSample.read(pid: candidate.root.pid)?.identity != candidate.root
                    || AgentProcessSample.read(pid: candidate.agent.pid)?.identity != candidate.agent
            }
            self.resetSupervisorObservationBackoff(for: session)
        }
    }
}
