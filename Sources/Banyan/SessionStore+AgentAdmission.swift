import BanyanCore
import Foundation

extension SessionStore {
    func configureAgentAdmission(_ session: BanyanSession) {
        session.agentAdmission = agentAdmission
        if let puck = session as? PuckSession {
            if !agentAdmission.running.contains(puck.id), let old = admissionTerminals.removeValue(forKey: puck.id) {
                watchAgentAdmissionProcess(old, pid: nil)
                old.agentAdmission = nil
            }
            admissionPuckSessions[puck.id] = puck
            puck.onAdmissionTurnStarting = { [weak self] in self?.startPuckObservation() }
            if [.executing, .asking, .subagents, .longRunningShell].contains(session.status) { agentAdmission.adopt(session.id) }
        }
        if let terminal = session as? TerminalSession {
            if let old = admissionPuckSessions.removeValue(forKey: terminal.id) { old.agentAdmission = nil }
            admissionTerminals[terminal.id] = terminal
            terminal.onAgentProviderIdentityRecorded = { [weak self, weak terminal] identity in
                guard let terminal else { return }
                self?.recordAgentProviderIdentity(id: terminal.id, identity: identity)
            }
            terminal.onAgentBackendReady = { [weak self, weak terminal] in
                guard let self, let terminal, self.selectedSessionID == terminal.id else { return }
                terminal.attachAdmittedTerminalClientIfNeeded()
            }
            terminal.onAgentRuntimeChanged = { [weak self, weak terminal] in
                guard let self, let terminal else { return }
                self.reconcileAgentAdmission(id: terminal.id)
            }
        }
    }

    func publishAgentAdmission() {
        let previous = lastPublishedAgentReservations
        lastPublishedAgentReservations = agentAdmission.running
        for session in sessions {
            if previous.contains(session.id) != agentAdmission.running.contains(session.id) { session.touch() }
            let position = agentAdmission.position(of: session.id)
            if session.agentQueuePosition != position { session.agentQueuePosition = position }
        }
        objectWillChange.send()
    }

    func cancelQueuedAgent(id: String) {
        guard agentAdmission.position(of: id) != nil else { return }
        if let terminal = sessions.first(where: { $0.id == id }) as? TerminalSession {
            var state = terminal.agentLaunchQueue ?? .init()
            state.cancelled = true
            terminal.agentLaunchQueue = state
            terminal.touch()
        }
        agentAdmission.cancel(id)
    }

    func prioritizeQueuedAgent(id: String) {
        guard agentAdmission.position(of: id) != nil else { return }
        if let terminal = sessions.first(where: { $0.id == id }) as? TerminalSession,
           let earliest = terminalSessions.compactMap({ $0.agentLaunchQueue?.requestedAt }).min() {
            terminal.agentLaunchQueue?.requestedAt = earliest.addingTimeInterval(-1)
            terminal.touch()
        }
        agentAdmission.prioritize(id)
    }

    func retryQueuedAgent(id: String) {
        guard let terminal = sessions.first(where: { $0.id == id }) as? TerminalSession else { return }
        let purpose = terminal.agentLaunchQueue?.purpose
        terminal.agentLaunchQueue = nil
        if purpose == .deepResume {
            do { try terminal.beginDeepResume() } catch { terminal.deepSuspendError = error.localizedDescription }
        } else if purpose == .restart {
            terminal.restartBackingSession()
        } else { terminal.startBackgroundBackendIfNeeded() }
    }

    /// Deep-resume/focus/input callers must reserve BEFORE injecting a launch.
    func requestAgentAdmission(id: String, retry: @escaping () -> Void) -> Bool {
        guard let terminal = admissionTerminals[id] else { return false }
        return terminal.requestAgentAdmission(retry: retry)
    }

    /// The deep-suspend journal supplies a kernel identity, never a bare PID.
    func recordAgentProviderIdentity(id: String, identity: AgentProcessIdentity) {
        guard let terminal = admissionTerminals[id], agentAdmission.running.contains(id) else { return }
        if terminal.admissionProviderIdentity != identity {
            terminal.admissionGeneration = UUID()
            terminal.admissionCaptureTask?.cancel()
            terminal.admissionCaptureTask = nil
        }
        terminal.admissionProviderIdentity = identity
        terminal.admissionConfirmedExitPID = nil
        watchAgentAdmissionProcess(terminal, pid: identity.pid)
        terminal.touch()
    }

    /// Call only after provider/tree termination is confirmed. A preserved pane
    /// may still be alive. A delayed callback from an older provider is ignored.
    func confirmAgentProviderExit(id: String, identity: AgentProcessIdentity) {
        guard let terminal = admissionTerminals[id], !terminal.backingLaunchInFlight,
              agentAdmission.running.contains(id),
              terminal.admissionProviderIdentity == identity else { return }
        if terminal.admissionConfirmedExitPID != identity.pid {
            guard case .exited = terminal.admissionProcessProbe(identity.pid, identity) else {
                terminal.admissionInspectionError = "Provider exit is not confirmed; its slot is retained."
                return
            }
        }
        terminal.admissionGeneration = UUID()
        // Keep the completed identity as provenance for the surviving shell
        // and restoration. A new admitted launch clears it before injection.
        terminal.admissionInspectionError = nil
        watchAgentAdmissionProcess(terminal, pid: nil)
        agentAdmission.release(id)
    }

    private func watchAgentAdmissionProcess(_ terminal: TerminalSession, pid: Int32?) {
        let identity = terminal.admissionProviderIdentity ?? terminal.admissionProcessIdentity
        if let key = terminal.admissionWatchKey, let owner = admissionWatchOwners[key],
           owner.generation == terminal.admissionGeneration, owner.pid == pid, owner.identity == identity { return }
        if let key = terminal.admissionWatchKey {
            admissionWatchOwners.removeValue(forKey: key)
            admissionProcessExitMonitor.update(sessionID: key, processIDs: [])
            terminal.admissionWatchKey = nil
        }
        guard let pid else { return }
        let key = UUID().uuidString
        admissionWatchOwners[key] = (terminal.id, terminal.admissionGeneration, pid, identity)
        terminal.admissionWatchKey = key
        admissionProcessExitMonitor.update(sessionID: key, processIDs: [pid])
    }

    func noteAgentAdmissionProcessExit(key: String) {
        guard let owner = admissionWatchOwners[key], let terminal = admissionTerminals[owner.id],
              terminal.admissionWatchKey == key, terminal.admissionGeneration == owner.generation,
              (terminal.admissionProviderIdentity ?? terminal.admissionProcessIdentity) == owner.identity else { return }
        // An exit event belongs to this watch generation and kernel identity,
        // including the zombie-before-parent-reap window. Never infer a new
        // provider's exit from an old watch sharing the same session ID/PID.
        if owner.identity != nil { terminal.admissionConfirmedExitPID = owner.pid }
        reconcileAgentAdmission(id: owner.id)
    }

    func reconcileAgentAdmission(id: String) {
        guard let terminal = admissionTerminals[id], !terminal.backingLaunchInFlight else { return }
        if let ticket = terminal.suspendTicket {
            if ticket.phase == .resuming {
                // The old provider has exited, but a new launch was already
                // injected. Pending/unknown restored startup remains reserved.
                if !agentAdmission.running.contains(id) { agentAdmission.adopt(id) }
            } else if agentAdmission.running.contains(id), terminal.admissionProviderIdentity != ticket.agent {
                recordAgentProviderIdentity(id: id, identity: ticket.agent)
            }
        }
        guard
              agentAdmission.running.contains(id) else { return }
        let backend = terminal.tmuxBackend
        let name = terminal.tmuxSessionName
        let generation = terminal.admissionGeneration
        let isProvider = terminal.admissionProviderIdentity != nil && !terminal.deepRecoveryIsUncertain && terminal.suspendTicket?.phase != .resuming
        let previousIdentity = isProvider ? terminal.admissionProviderIdentity : terminal.admissionProcessIdentity
        let previousPID = isProvider ? terminal.admissionProviderIdentity?.pid : terminal.admissionPanePID
        let launchSucceeded = terminal.admissionLaunchSucceeded
        let confirmedExitPID = terminal.admissionConfirmedExitPID
        let probe = terminal.admissionProcessProbe
        let rootIdentity = terminal.admissionProcessIdentity
        Task.detached(priority: .utility) { [weak self, weak terminal] in
            let inspection = backend.agentAdmissionPane(named: name)
            let pane: TmuxPaneSnapshot?
            let paneAbsent: Bool
            switch inspection {
            case .present(let value): pane = value; paneAbsent = false
            case .absent: pane = nil; paneAbsent = true
            case .unknown: pane = nil; paneAbsent = false
            }
            let pid = previousPID ?? pane.flatMap { Int32(exactly: $0.rootPID) }
            let process: AgentAdmissionProcessInspection = pid != nil && confirmedExitPID == pid ? .exited : (pid.map { probe($0, previousIdentity) } ?? .unknown)
            let commandIdentity = rootIdentity.flatMap { AgentAdmissionProcessInspection.persistentCommandIdentity(root: $0) }
            let recordedEnded: Bool
            if case .exited = process { recordedEnded = true } else { recordedEnded = false }
            var replacementIdentity: AgentProcessIdentity?
            if !isProvider, case .exited = process, let pane, !pane.isDead,
               let currentPID = Int32(exactly: pane.rootPID),
               case .running(let identity) = probe(currentPID, nil), identity != previousIdentity {
                replacementIdentity = identity
            }
            let replacement = replacementIdentity
            await MainActor.run { [weak self, weak terminal] in
                guard let self, let terminal, self.admissionTerminals[id] === terminal,
                      terminal.admissionGeneration == generation, !terminal.backingLaunchInFlight else { return }
                if let commandIdentity, commandIdentity != previousIdentity, (!isProvider || recordedEnded), terminal.suspendTicket == nil {
                    self.recordAgentProviderIdentity(id: id, identity: commandIdentity)
                    return
                }
                switch process {
                case .running(let identity):
                    if !isProvider {
                        terminal.admissionPanePID = pid
                        if let identity { terminal.admissionProcessIdentity = identity }
                    }
                    terminal.admissionInspectionError = identity == nil ? "Agent identity could not be inspected; its slot is retained." : nil
                    if let pid { self.watchAgentAdmissionProcess(terminal, pid: pid) }
                    if !isProvider { terminal.captureAgentCommandIdentityIfNeeded() }
                case .exited:
                    if isProvider, let previousIdentity {
                        self.confirmAgentProviderExit(id: id, identity: previousIdentity)
                    } else if let replacement {
                        // An independently replaced pane can outlive the old
                        // identity. Count its current process rather than free it.
                        terminal.admissionGeneration = UUID()
                        terminal.admissionProcessIdentity = replacement
                        terminal.admissionPanePID = replacement.pid
                        terminal.admissionConfirmedExitPID = nil
                        self.watchAgentAdmissionProcess(terminal, pid: replacement.pid)
                    } else if previousIdentity != nil || paneAbsent || (pane?.rootPID == pid.map(Int.init) && (pane?.isDead == true || confirmedExitPID == pid)) {
                        terminal.admissionGeneration = UUID()
                        self.agentAdmission.release(id)
                        terminal.admissionInspectionError = nil
                        self.watchAgentAdmissionProcess(terminal, pid: nil)
                    } else {
                        terminal.admissionInspectionError = "Pane state is uncertain; its agent slot is retained. Recheck when tmux is available."
                    }
                case .unknown:
                    if let pid { self.watchAgentAdmissionProcess(terminal, pid: pid) }
                    if !launchSucceeded && paneAbsent && previousPID == nil {
                        // A failed creation with a confirmed absent session never
                        // owned a process. Successful uninspected launches stay held.
                        self.agentAdmission.release(id)
                    } else {
                        terminal.admissionInspectionError = "Agent exit could not be verified; its slot is retained. Recheck when process inspection is available."
                    }
                }
            }
        }
    }

}

extension TerminalSession {
    var canReuseCompletedAgentPane: Bool {
        guard agentAdmission?.running.contains(id) == false, let provider = admissionProviderIdentity,
              let root = admissionProcessIdentity else { return false }
        let exited: Bool
        if admissionConfirmedExitPID == provider.pid { exited = true }
        else if case .exited = admissionProcessProbe(provider.pid, provider) { exited = true }
        else { exited = false }
        guard exited, case .present(let pane) = tmuxBackend.agentAdmissionPane(named: tmuxSessionName),
              !pane.isDead, pane.rootPID == Int(root.pid), AgentProcessSample.read(pid: root.pid)?.identity == root else { return false }
        return true
    }

    /// Only a bounded startup handshake, never an unrelated repeating poll.
    /// The inner process host exists before adapter/provider initialization.
    /// Once captured, its kernel exit event accounts for ordinary /quit too.
    func captureAgentCommandIdentityIfNeeded() {
        guard admissionCaptureTask == nil, admissionProviderIdentity == nil,
              AgentProcessHost.supportsPersistentShell(command: command),
              let root = admissionProcessIdentity else { return }
        let generation = admissionGeneration
        admissionCaptureTask = Task { [weak self] in
            for delay in [0, 50, 100, 200, 400, 800, 1_600] {
                if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
                guard let self, !Task.isCancelled, self.admissionGeneration == generation,
                      self.agentAdmission?.running.contains(self.id) == true else { return }
                let identity = await Task.detached(priority: .utility) {
                    AgentAdmissionProcessInspection.persistentCommandIdentity(root: root)
                }.value
                guard !Task.isCancelled, self.admissionGeneration == generation else { return }
                if let identity { self.onAgentProviderIdentityRecorded?(identity); return }
            }
            // A command which exited before identity capture remains uncertain.
            self?.admissionInspectionError = "Command identity could not be captured; its slot is retained. Recheck when process inspection is available."
        }
    }

    /// All backing-session creation paths, including same-pane deep resume,
    /// must call this BEFORE ensure/restart. Parking/freezing never releases it.
    func requestAgentAdmission(queueIfBusy: Bool = true, purpose: AgentLaunchQueueState.Purpose? = nil, retry: @escaping () -> Void) -> Bool {
        guard let admission = agentAdmission,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || agentProvider != nil || admissionProviderIdentity != nil else { return true }
        guard agentLaunchQueue?.cancelled != true else { return false }
        let wasRunning = admission.running.contains(id)
        let generation = admissionGeneration
        let sessionID = id
        if !queueIfBusy {
            guard admission.acquireImmediately(id) else { return false }
            if !wasRunning { resetAgentAdmissionForLaunch() }
            return true
        }
        if admission.request(id, start: { [weak self, weak admission] in
            guard let self, self.admissionGeneration == generation, self.status != .closed, !self.isSuspended,
                  self.agentLaunchQueue?.cancelled != true else {
                admission?.release(sessionID)
                return
            }
            self.resetAgentAdmissionForLaunch()
            self.agentLaunchQueue = nil
            self.agentQueuePosition = nil
            self.touch()
            retry()
        }) {
            if !wasRunning {
                resetAgentAdmissionForLaunch()
            }
            agentLaunchQueue = nil
            agentQueuePosition = nil
            return true
        }
        if agentLaunchQueue == nil { agentLaunchQueue = .init(purpose: purpose) }
        agentQueuePosition = admission.position(of: id)
        if status == .closed { status = .running }
        touch()
        return false
    }

    private func resetAgentAdmissionForLaunch() {
        admissionCaptureTask?.cancel()
        admissionCaptureTask = nil
        admissionGeneration = UUID()
        admissionProviderIdentity = nil
        admissionPanePID = nil
        admissionConfirmedExitPID = nil
        admissionProcessIdentity = nil
        admissionLaunchSucceeded = false
    }
}
