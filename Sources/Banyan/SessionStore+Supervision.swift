import BanyanCore
import Foundation
import AppKit
import SwiftUI

extension SessionStore {
    /// Resolve the provider session behind a closed Banyan row. The live title
    /// matcher intentionally uses a narrow launch-time window to avoid assigning
    /// the wrong title among concurrent sessions. Reopen can be more practical:
    /// Codex and Claude scope their resume pickers by cwd, and Linear worktrees are
    /// normally unique. Prefer the strict match, then use the exact provider + cwd;
    /// if several transcripts share that directory, choose the one whose last
    /// activity is closest to when the Banyan session was last active.
    func detectAttention(in text: String, for session: BanyanSession) {
        guard let result = detector.detect(in: text), session.status != .closed else { return }
        guard result.status == .asking || result.status == .needInput else { return }
        guard ![.executing, .longRunningShell, .subagents].contains(session.status) else { return }
        session.mark(status: result.status, tone: result.tone)
    }

    func runSupervisorTick(sessionID: String? = nil, force: Bool = false) {
        let now = Date()
        if force || sessionID != nil {
            for session in terminalSessions where session.status != .closed
                && !session.isSuspended && !session.isFrozen && !session.isDeepSuspended && (sessionID == nil || session.id == sessionID) {
                supervisorObservationStates[session.id, default: .init()].noteActivity(at: now)
                pendingSupervisorActivityIDs.insert(session.id)
                pendingSupervisorSignalIDs.insert(session.id)
            }
        }
        guard supervisorTickSchedule.begin() else { return }
        // One-shot scheduling consumes all deadlines while this tick is running.
        // Also discard a timer callback already queued on the main actor.
        supervisorTimerGeneration = UUID()
        supervisorTimer?.invalidate()
        supervisorTimer = nil
        let candidates = terminalSessions.compactMap { session -> SessionStatusObservationInput? in
            guard session.status != .closed && !session.isFrozen && !session.isDeepSuspended && (sessionID == nil || session.id == sessionID),
                  SessionLifecyclePolicy.participatesInSupervisorTick(
                      isProcessStarted: session.isProcessStarted,
                      isRestored: session.isRestored,
                      isSuspended: session.isSuspended
                  ) else { return nil }
            return SessionStatusObservationInput(
                id: session.id,
                tmuxSessionName: session.tmuxSessionName,
                command: session.command,
                status: session.status,
                isAwaitingAttach: !session.isProcessStarted,
                cwd: session.cwd,
                createdAt: session.createdAt,
                environment: session.environment
            )
        }
        let liveIDs = Set(terminalSessions.filter { $0.status != .closed && !$0.isSuspended && !$0.isFrozen && !$0.isDeepSuspended }.map(\.id))
        supervisorProcessExitMonitor.retainSessions(liveIDs)
        pendingSupervisorActivityIDs.formIntersection(Set(terminalSessions.filter {
            $0.status != .closed && !$0.isFrozen && !$0.isDeepSuspended && SessionLifecyclePolicy.participatesInSupervisorTick(
                isProcessStarted: $0.isProcessStarted, isRestored: $0.isRestored, isSuspended: $0.isSuspended
            )
        }.map(\.id)))
        pendingSupervisorActivityIDs.subtract(candidates.map(\.id))
        pendingSupervisorSignalIDs.formIntersection(pendingSupervisorActivityIDs)
        guard !candidates.isEmpty else {
            supervisorTickSchedule.finish(at: now, minimumRest: 1)
            rescheduleSupervisor()
            return
        }

        let backend = tmuxBackend
        let processTableProvider = processTable
        let promptScope = slackPromptObservationScope()
        let promptSessionIDs = promptScope.ids, promptActivation = promptScope.token
        let inspectionCache = supervisorInspectionCache
        let states = supervisorObservationStates
        let cadence = force || sessionID != nil ? supervisorInterval : supervisorScheduledInterval
        let telemetry = self.telemetry
        Task.detached(priority: .utility) { [weak self, telemetry] in
            let tickStartedAt = DispatchTime.now()
            // Probe all participating panes once. Changed activity wakes a
            // deferred session in this tick, without a second list-panes call.
            let panes = backend.primaryPaneSnapshots(named: Set(candidates.map(\.tmuxSessionName)))
            let inputs = candidates.filter {
                force || sessionID != nil || states[$0.id]?.isDue(pane: panes[$0.tmuxSessionName], at: now) != false
            }
            var results: [SessionStatusObservation] = []
            if !inputs.isEmpty {
                let synchronizer = SessionStatusSynchronizer(
                    backend: backend,
                    processTable: processTableProvider.snapshot(),
                    cache: inspectionCache
                )
                results = synchronizer.observe(inputs, paneSnapshots: panes, promptSessionIDs: promptSessionIDs,
                                               promptActivationID: promptActivation) { sessionID, durationMS in
                    telemetry.recordDurationIfSlow(
                        "supervisor.session",
                        durationMS: durationMS,
                        sessionID: sessionID
                    )
                }
            }
            let durationMS = PerformanceTelemetry.elapsedMS(since: tickStartedAt)
            let observations = results
            await MainActor.run { [weak self] in
                guard let self else { return }
                // Events received while the subprocesses were running keep their
                // due state. State signals may also have superseded this result.
                let currentResults = observations.filter {
                    let id = $0.id
                    return self.sessions.contains(where: { $0.id == id && $0.status != .closed && !$0.isSuspended && !$0.isFrozen && !$0.isDeepSuspended })
                        && (self.supervisorObservationStates[id]?.resultRevision ?? 0) == (states[id]?.resultRevision ?? 0)
                }
                self.updateSupervisorObservationStates(
                    for: inputs,
                    results: currentResults,
                    panes: panes,
                    startedStates: states,
                    observedAt: Date()
                )
                self.applySupervisorResults(currentResults)
                self.supervisorTickSchedule.finish(at: Date(), minimumRest: min(2, self.supervisorBaseInterval))
                self.rescheduleSupervisor()
                let nextDelay = max(0, self.supervisorTimerDueAt.timeIntervalSinceNow)
                telemetry.recordDurationLocalIfSlow(
                    "supervisor.tick",
                    durationMS: durationMS,
                    detail: "sessions=\(candidates.count) observed=\(inputs.count) deferred=\(candidates.count - inputs.count) cadence_s=\(Int(cadence.rounded())) next_delay_s=\(Int(nextDelay.rounded())) effective_cadence_s=\(String(format: "%.2f", durationMS / 1000 + nextDelay)) schedule=after_completion"
                )
            }
        }
    }

    func resetSupervisorObservationBackoff(for sessionID: String, invalidatesObservation: Bool = true) {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return }
        resetSupervisorObservationBackoff(for: session, invalidatesObservation: invalidatesObservation)
    }

    /// Output callbacks already know their session. Keep this path independent
    /// of fleet size, but record every chunk so activity during an inspection
    /// still prevents that inspection from restoring an obsolete backoff.
    func resetSupervisorObservationBackoff(for session: BanyanSession, invalidatesObservation: Bool = true) {
        guard session is TerminalSession, session.status != .closed,
              !session.isSuspended, !session.isFrozen, !session.isDeepSuspended else { return }
        supervisorObservationStates[session.id, default: .init()].noteActivity(at: Date(), invalidatesObservation: invalidatesObservation)
        let newlyPending = pendingSupervisorActivityIDs.insert(session.id).inserted
        let newlySignalled = invalidatesObservation && pendingSupervisorSignalIDs.insert(session.id).inserted
        if didStartSupervisor && (newlyPending || newlySignalled) { rescheduleSupervisor() }
    }

    private func updateSupervisorObservationStates(
        for inputs: [SessionStatusObservationInput],
        results: [SessionStatusObservation],
        panes: [String: TmuxPaneSnapshot],
        startedStates: [String: SessionSupervisorObservationState],
        observedAt: Date
    ) {
        let baseInterval = supervisorBaseInterval
        let resultsByID = Dictionary(uniqueKeysWithValues: results.map { ($0.id, $0) })
        for input in inputs {
            guard let session = sessions.first(where: { $0.id == input.id }),
                  session.status != .closed, !session.isSuspended, !session.isFrozen, !session.isDeepSuspended else { continue }
            let result = resultsByID[input.id]
            supervisorObservationStates[input.id, default: .init()].record(
                result,
                pane: panes[input.tmuxSessionName],
                startedRevision: startedStates[input.id]?.revision ?? 0,
                at: observedAt,
                baseInterval: baseInterval,
                isSelectedAttached: isSelectedAttached(session)
            )
            if let result {
                supervisorProcessExitMonitor.update(sessionID: input.id, processIDs: result.liveProcessIDs)
            }
        }
        let liveIDs = Set(terminalSessions.filter { $0.status != .closed && !$0.isSuspended && !$0.isFrozen && !$0.isDeepSuspended }.map(\.id))
        supervisorObservationStates = supervisorObservationStates.filter { liveIDs.contains($0.key) }
        supervisorProcessExitMonitor.retainSessions(liveIDs)
    }

    @discardableResult
    func applySupervisorResults(_ results: [SessionStatusObservation]) -> Bool {
        var didUpdateProvider = false
        var didChangePersistentState = false
        let promptScope = slackPromptObservationScope()
        for var result in results {
            guard let session = sessions.first(where: { $0.id == result.id }) as? TerminalSession,
                  !session.isFrozen, !session.isDeepSuspended else { continue }
            observeCodexRetry(session, observation: result)
            if awayPromptActivationID != promptScope.token {
                awayPromptActivationID = promptScope.token
                awayPromptFootprints = slackDecisionJournal.observedPromptFootprints(allowed: codexRemote.policy.allowed)
            }
            if result.promptObserved, result.promptActivationID == promptScope.token,
               promptScope.ids.contains(session.id) {
                let previous = awayPromptFootprints[session.id]
                if let footprint = result.promptFootprint { awayPromptFootprints[session.id] = footprint }
                else { awayPromptFootprints.removeValue(forKey: session.id) }
                // Status transitions already generate an event. Emit a second
                // kind only when the prompt changed while the status did not.
                if previous != result.promptFootprint, session.status == result.status {
                    let event = sessionEventLog.append(sessionID: session.id, status: result.status, previousStatus: session.status)
                    onSessionEvent?(event)
                }
            }
            if result.status == .closed, session.workflow?.state.permitsClose == false {
                // Missing process ≠ closed issue. Keep managed rows visible and
                // their worktrees owned while the supervisor recovers the thread.
                result = SessionStatusObservation(id: result.id, status: .completed, tone: .neutral,
                    provider: result.provider, modelID: result.modelID, modelIDIsExact: result.modelIDIsExact,
                    currentPath: result.currentPath)
                session.needsRecovery = true
            }
            let backgroundCount = session.status == .closed ? 0 : result.backgroundTerminalCount
            if session.backgroundTerminalCount != backgroundCount {
                session.backgroundTerminalCount = backgroundCount
                // Background work also changes the verified-session cleanup menu.
                if session.workflow?.state == .verified { objectWillChange.send() }
            }
            guard let reconciliation = SessionObservationPolicy.reconcile(
                      currentStatus: session.status,
                      currentTone: session.tone,
                      currentProvider: session.detectedAgentProvider,
                      currentModelID: session.detectedAgentModelID,
                      currentPath: session.cwd,
                      observation: result
                  ) else {
                continue
            }
            var didChangeSession = false
            if reconciliation.providerChanged {
                session.markDetectedAgentProvider(result.provider)
                didUpdateProvider = true
                didChangeSession = true
            }
            if reconciliation.modelChanged {
                session.markDetectedAgentModel(result.modelID, isExact: result.modelIDIsExact)
            }
            if reconciliation.currentPathChanged, let currentPath = result.currentPath {
                session.updateCurrentDirectory(currentPath)
                didChangeSession = true
            }
            var didStartAgentTurn = false
            if reconciliation.runtimeStateChanged {
                // Read the old status first: a turn that has just begun is the
                // moment the transcript gains the first prompt, which is the
                // only thing that can title a session the agent never names.
                didStartAgentTurn = result.status == .executing && session.status != .executing
                session.mark(status: result.status, tone: result.tone)
                didChangeSession = true
            }
            // Queued work can take a reservation from an idle command; the first
            // observation of it working again gives that reservation back.
            adoptObservedAgentActivity(id: session.id)
            if didStartAgentTurn {
                scheduleAgentTitleImportIfNeeded(for: session)
            }
            if didChangeSession {
                didChangePersistentState = true
                saveChangedSession(session)
            }
        }
        if didUpdateProvider {
            refreshLiveAgentTitles(from: latestImportedHistory)
        }
        return didChangePersistentState
    }
}
