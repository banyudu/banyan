import AppKit
import BanyanCore
import Foundation

extension SessionStore {
    func deepSuspendPolicy(for provider: CodingAgentProvider) -> AgentDeepSuspendPolicy {
        let key = "agentDeepSuspend.\(provider.rawValue)"
        guard let data = freezePreferences.data(forKey: key),
              let policy = try? JSONDecoder().decode(AgentDeepSuspendPolicy.self, from: data) else { return .init() }
        return policy
    }

    func setDeepSuspendPolicy(_ policy: AgentDeepSuspendPolicy, for provider: CodingAgentProvider) {
        freezePreferences.set(try? JSONEncoder().encode(policy), forKey: "agentDeepSuspend.\(provider.rawValue)")
        nextDeepSuspendProbeAt = .distantPast
        deepSuspendPolicyDidChange()
        objectWillChange.send()
    }

    func deepResumeAgent(id: String) throws {
        guard let terminal = sessions.first(where: { $0.id == id }) as? TerminalSession else {
            throw ControlError.badRequest("deep resume requires a terminal agent session")
        }
        try terminal.beginDeepResume()
        resetSupervisorObservationBackoff(for: id)
    }

    func deepSuspendAgent(id: String, automatic: Bool = false, underPressure: Bool = false) async throws {
        guard !isAgentFreezeShuttingDown,
              let terminal = sessions.first(where: { $0.id == id }) as? TerminalSession,
              !terminal.isImportedHistory, !terminal.isSuspended, !terminal.isDeepResuming else {
            throw ControlError.badRequest("deep suspend requires a live terminal agent")
        }
        guard !terminal.deepRecoveryIsUncertain else {
            throw AgentFreezeError.unsafe("Recovery journal is unavailable; retry Resume before suspending")
        }
        if terminal.isDeepSuspended { return }
        guard !pendingAgentFreezeIDs.contains(id), !deepSuspendProtected(terminal),
              let provider = CodingAgentProvider.detect(in: terminal.command),
              [.claude, .codex, .opencode].contains(provider) else {
            throw AgentFreezeError.unsafe("Focused, busy, interacting or unsupported session")
        }
        let policy = deepSuspendPolicy(for: provider)
        guard !automatic || policy.automatic else { return }
        pendingAgentFreezeIDs.insert(id)
        defer { pendingAgentFreezeIDs.remove(id) }
        // Escalating tier one must run the full quiet check after CONT. Never
        // send TERM to a stopped process and mistake queued delivery for exit.
        if terminal.isFrozen {
            let interaction = terminal.lastFreezeInteractionAt
            try terminal.unfreezeAgent()
            terminal.lastFreezeInteractionAt = interaction
        }
        let generation = terminal.freezeGeneration
        let knownRoot = terminal.trackedPaneIdentity
        let backend = terminal.tmuxBackend
        let target = try paneTarget(id: id)
        let lastInteraction = terminal.lastFreezeInteractionAt
        let threshold = automatic ? policy.threshold(underPressure: underPressure) : 2
        let history = deepSuspendHistory
        let lifecycleGeneration = terminal.deepLifecycleGeneration
        var recorded: AgentSuspendTicket?
        do {
            let (ticket, plan, activity, first, started) = try await Task.detached(priority: .utility) {
                guard let pane = backend.primaryPaneSnapshot(named: target.tmuxSessionName),
                      !pane.isDead, !pane.isInMode, !pane.hasAttachedClients, let activity = pane.lastActivityAt,
                      let root = AgentProcessSample.read(pid: Int32(pane.rootPID))?.identity,
                      knownRoot == nil || knownRoot == root else {
                    throw AgentFreezeError.unsafe("Pane is missing, visible, or its identity changed")
                }
                let rows = ProcessTable.snapshot().descendants(of: pane.rootPID)
                guard let rootRow = rows.first(where: { $0.pid == pane.rootPID }), rootRow.isBanyanProcessHost,
                      rootRow.argumentVector?.dropFirst(2).first == AgentProcessHost.persistentFlag,
                      let shellRow = rows.first(where: { $0.parentPID == pane.rootPID }),
                      ["sh", "bash", "zsh", "fish", "ksh", "dash"].contains((shellRow.commandName as NSString).lastPathComponent),
                      shellRow.commandName.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: shellRow.commandName),
                      let shell = AgentProcessSample.read(pid: Int32(shellRow.pid))?.identity else {
                    throw AgentFreezeError.unsafe("Legacy one-shot pane has no surviving shell; relaunch using a literal provider command")
                }
                let agents = rows.filter { $0.isSupportedAgentForFreezing }
                // Node launchers may parent the native agent. Signal only the
                // single deepest provider process, never its launcher or MCPs.
                let leaves = agents.filter { agent in !agents.contains { $0.parentPID == agent.pid } }
                guard leaves.count == 1, let agent = leaves.first else {
                    throw AgentFreezeError.unsafe("Agent PID is ambiguous")
                }
                guard let sample = AgentProcessSample.read(pid: Int32(agent.pid)) else {
                    throw AgentFreezeError.unsafe("Agent disappeared")
                }
                guard let liveCommand = AgentDeepSuspend.providerCommand(provider: provider, process: agent) else {
                    throw AgentFreezeError.unsafe("Live provider arguments are unavailable; agent left running")
                }
                let candidates = history.resumeCandidates(cwd: target.cwd, provider: provider, maxFilesScanned: 20_000)
                let disk: AgentDiskSession
                var idleTranscriptPath: String?
                if let current = try AgentProviderIdentity.query(process: sample.identity, provider: provider, cwd: target.cwd) {
                    guard candidates.contains(where: { $0.provider == provider && $0.sourceID == current.id
                        && PathDisplayName.canonicalPath($0.cwd) == PathDisplayName.canonicalPath(current.cwd) }) else {
                        throw AgentFreezeError.unsafe("Current provider session has no recoverable disk record")
                    }
                    disk = current
                } else {
                    let open = try AgentDeepSuspend.openTranscripts(pid: Int32(agent.pid))
                    disk = try AgentDeepSuspend.resolve(provider: provider, command: liveCommand, cwd: target.cwd,
                        candidates: candidates, openTranscripts: open)
                    if provider == .codex { idleTranscriptPath = try AgentDeepSuspend.codexIdleTranscript(disk, open: open) }
                }
                let first = try AgentProcessFreezer.snapshot(rootPID: root.pid)
                let plan = try AgentProcessFreezer.plan(root: root, agentPIDs: [Int32(agent.pid)], samples: first)
                let host = URL(fileURLWithPath: rootRow.commandName)
                guard rootRow.commandName.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: host.path) else {
                    throw AgentFreezeError.unsafe("Process host is unavailable for recovery")
                }
                let command = try AgentDeepSuspend.resumeCommand(disk: disk, launchCommand: target.command,
                    host: host.path, shell: shellRow.commandName)
                let started = ProcessInfo.processInfo.systemUptime
                try await Task.sleep(for: .seconds(1))
                let second = try AgentProcessFreezer.snapshot(rootPID: root.pid)
                let finalRows = ProcessTable.snapshot().descendants(of: pane.rootPID)
                let result = AgentSupervisor(backend: backend,
                    processTable: AgentDeepSuspend.foregroundTable(rows: finalRows, agentPID: agent.pid)).inspect(
                    tmuxSessionName: target.tmuxSessionName, launchCommand: target.command, currentStatus: target.status,
                    cwd: target.cwd, sessionStartedAt: target.createdAt, environment: target.environment)
                guard let result, AgentInactivityPolicy.permitsSuspension(status: result.status, focused: false,
                    visible: false, quietSeconds: Date().timeIntervalSince(max(activity, lastInteraction)), threshold: threshold),
                      AgentProcessFreezer.isQuiet(first, second, ticket: plan, elapsed: ProcessInfo.processInfo.systemUptime - started),
                      let fresh = backend.primaryPaneSnapshot(named: target.tmuxSessionName), fresh.paneID == pane.paneID,
                      fresh.rootPID == pane.rootPID, fresh.lastActivityAt == activity,
                      !fresh.isDead, !fresh.isInMode, !fresh.hasAttachedClients else {
                    throw AgentFreezeError.unsafe("Agent output, CPU, status or visibility is active")
                }
                if let idleTranscriptPath { try AgentDeepSuspend.validateCodexIdleTranscript(idleTranscriptPath, disk: disk) }
                let ticket = AgentSuspendTicket(root: root, shell: shell, agent: sample.identity, paneID: pane.paneID,
                    disk: disk, resumeCommand: command, residentBytes: sample.residentBytes,
                    survivors: first.filter { $0.identity != root && $0.identity != shell && $0.identity != sample.identity }.map(\.identity),
                    idleTranscriptPath: idleTranscriptPath)
                return (ticket, plan, activity, first, started)
            }.value
            // Main-actor commit: focus/input invalidate the generation. There
            // is no await from this guard through journal creation and TERM.
            // Closed/removed sessions cannot be journaled by preparation tasks.
            guard sessions.contains(where: { $0 === terminal }), terminal.freezeGeneration == generation,
                  terminal.deepLifecycleGeneration == lifecycleGeneration, !Task.isCancelled,
                  !isAgentFreezeShuttingDown, !deepSuspendProtected(terminal),
                  !automatic || deepSuspendPolicy(for: provider).automatic else {
                throw AgentFreezeError.unsafe("Session became focused or changed during preparation")
            }
            try backend.writeSuspendTicket(ticket, named: target.tmuxSessionName)
            recorded = ticket
            guard let finalPane = backend.primaryPaneSnapshot(named: target.tmuxSessionName),
                  finalPane.paneID == ticket.paneID, Int32(finalPane.rootPID) == ticket.root.pid,
                  finalPane.lastActivityAt == activity, !finalPane.hasAttachedClients, !finalPane.isInMode,
                  !finalPane.isDead,
                  AgentProcessFreezer.isQuiet(first, try AgentProcessFreezer.snapshot(rootPID: ticket.root.pid), ticket: plan,
                      elapsed: ProcessInfo.processInfo.systemUptime - started) else {
                throw AgentFreezeError.unsafe("Agent became active while recording recovery")
            }
            try AgentDeepSuspend.terminateAgent(ticket, freezePlan: plan)
            terminal.suspendTicket = ticket
            terminal.isDeepSuspended = true
            terminal.isDeepTerminating = true
            terminal.watchDeepTermination(ticket)
            terminal.agentSessionID = ticket.disk.id
            terminal.trackedPaneIdentity = ticket.root
            terminal.deepSuspendError = nil
            terminal.touch()
            // TERM is graceful and can be ignored. Success means the address
            // space actually vanished. Never escalate to group kill or SIGKILL.
            for _ in 0..<30 {
                guard terminal.deepLifecycleGeneration == lifecycleGeneration, terminal.status != .closed,
                      sessions.contains(where: { $0 === terminal }) else { throw CancellationError() }
                if AgentProcessSample.presence(of: ticket.agent) == .exited { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard AgentProcessSample.presence(of: ticket.agent) == .exited else {
                throw AgentFreezeError.unsafe("Agent has not exited after TERM; recovery retained while waiting for graceful exit")
            }
            terminal.completeDeepTermination(ticket)
            saveSessions()
        } catch {
            guard terminal.status != .closed, terminal.deepLifecycleGeneration == lifecycleGeneration,
                  sessions.contains(where: { $0 === terminal }) else { throw error }
            if let ticket = recorded, !terminal.isDeepSuspended,
               backend.suspendTicket(named: target.tmuxSessionName) == ticket {
                try? backend.writeSuspendTicket(nil, named: target.tmuxSessionName)
                if terminal.suspendTicket == ticket { terminal.suspendTicket = nil }
            }
            terminal.deepSuspendError = error.localizedDescription
            telemetry.recordDuration("agent.deep_suspend_refused", durationMS: 0, sessionID: id, detail: error.localizedDescription)
            throw error
        }
    }

    private func deepSuspendProtected(_ terminal: TerminalSession) -> Bool {
        terminal.id == selectedSessionID || terminal.id == selection.selectedSessionID || terminal.freezeInputInFlight > 0
            || terminal.status == .closed || ![.idle, .needInput].contains(terminal.status)
    }

    func runDeepSuspendPass(now: Date = Date(), underPressure: Bool = false) {
        guard !isAgentFreezeShuttingDown, !isDeepSuspendPassRunning,
              now >= nextDeepSuspendProbeAt else { return }
        nextDeepSuspendProbeAt = now.addingTimeInterval(NSApp?.isActive == true ? 60 : 120)
        let ids = AgentDeepSuspend.leastRecentlyUsed(terminalSessions.map { session in
            let policy = session.agentProvider.map { deepSuspendPolicy(for: $0) } ?? .init()
            return AgentSuspendCandidate(id: session.id, lastInteraction: session.lastFreezeInteractionAt,
                eligible: policy.automatic && !session.isDeepSuspended && !session.isSuspended
                    && !deepSuspendProtected(session)
                    && now.timeIntervalSince(session.lastFreezeInteractionAt) >= policy.threshold(underPressure: underPressure))
        })
        guard !ids.isEmpty else { return }
        isDeepSuspendPassRunning = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isDeepSuspendPassRunning = false }
            for id in ids {
                do { try await self.deepSuspendAgent(id: id, automatic: true, underPressure: underPressure) }
                catch { continue }
                // Reclaim one LRU address space per pressure event; further
                // critical events continue down the LRU list.
                if underPressure { break }
            }
        }
    }

    func startDeepSuspendPressureMonitor() {
        guard deepSuspendPressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            let pressured = !(source?.data.contains(.normal) ?? true)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isUnderMemoryPressure = pressured
                self.nextDeepSuspendProbeAt = .distantPast
                if pressured { self.runDeepSuspendPass(underPressure: true) }
                self.deepSuspendPolicyDidChange()
            }
        }
        deepSuspendPressureSource = source
        source.resume()
    }
}
