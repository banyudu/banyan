import AppKit
import BanyanCore
import Foundation
import SwiftTerm

extension TerminalSession {
    func renderRestoredMessageIfNeeded(theme: TerminalTheme, fontFamily: String? = nil, fontSize: Double = 13) {
        guard needsManualAttach, !didRenderRestoredMessage else { return }
        // Only meaningful once the terminal is on screen, which means it already exists.
        guard let terminalView = loadedTerminalView else { return }
        guard terminalView.bounds.width > 80, terminalView.bounds.height > 80 else { return }
        theme.apply(to: terminalView, fontFamily: fontFamily, fontSize: fontSize)
        terminalView.resizeSubviews(withOldSize: .zero)
        terminalView.feed(text: restoredMessage())
        didRenderRestoredMessage = true
    }

    func start() {
        guard !isImportedHistory, !isSuspended else { return }
        guard !terminalView.process.running else { return }
        isDetachingTerminalClient = false
        let startedAt = DispatchTime.now()
        startTerminalClient()
        telemetry.recordDuration(
            "terminal.start_client",
            durationMS: PerformanceTelemetry.elapsedMS(since: startedAt),
            sessionID: id,
            detail: "tmux=\(tmuxSessionName)"
        )
    }

    /// Async foreground start for terminal-ready paths that run on the main
    /// thread during a session switch. `startTerminalClient` runs several tmux
    /// subprocesses synchronously (`ensureBackingSession` + theme options, each
    /// with a 10s timeout); doing that on the main thread is what froze the UI
    /// for seconds on first-visit switches (`switcher.switch_visible` p50
    /// ~8s). The tmux ensure runs on a background task and the PTY attach
    /// happens back on the main actor. Revisits no-op fast on the main thread
    /// when the client is already running.
    func startAsync() {
        guard !isImportedHistory, !isSuspended, status != .closed,
              let terminalView = loadedTerminalView, !terminalView.process.running else { return }
        // Fast path: backing session already exists, attach synchronously like
        // `start()` without paying a hop. `hasSession` is one cheap tmux call;
        // if it says yes there is nothing blocking left to do off-main.
        // NOTE: even one tmux call can block up to 10s on a wedged server, so
        // this fast path is best-effort. A slow `hasSession` still stalls the
        // switch; the full-async fallback below covers the common first-visit
        // case where the backing session is known-absent (`!isProcessStarted`).
        if isProcessStarted {
            start()
            return
        }
        if canReuseCompletedAgentPane { start(); return }
        guard !backingLaunchInFlight else { return }
        guard ensureProjectFolderAccess() else { return }
        guard requestAgentAdmission(retry: { [weak self] in self?.startBackgroundBackendIfNeeded() }) else { return }
        backingLaunchInFlight = true
        admissionGeneration = UUID()
        isDetachingTerminalClient = false
        let runtime = sessionRuntime
        let request = launchRequest
        let backend = tmuxBackend
        let themeStyle = pendingTheme.tmuxDefaultStyle
        let telemetry = telemetry
        let sessionID = id
        let tmuxName = tmuxSessionName
        let startedAt = DispatchTime.now()
        let generation = terminalClientGeneration
        Task.detached(priority: .userInitiated) { [weak self, weak terminalView] in
            backend.configureTerminalTheme(style: themeStyle, for: nil)
            do {
                try runtime.ensureBackingSession(request)
            } catch {
                let message = error.localizedDescription
                await MainActor.run { [weak self, weak terminalView] in
                    guard let self else { return }
                    self.backingLaunchInFlight = false
                    self.onAgentRuntimeChanged?()
                    guard let terminalView,
                          self.terminalClientGeneration == generation,
                          self.loadedTerminalView === terminalView else { return }
                    self.failToStart(message)
                }
                return
            }
            let admissionPane = backend.primaryPaneSnapshot(named: tmuxName)
            let paneIdentity = admissionPane.flatMap { AgentProcessSample.read(pid: Int32($0.rootPID))?.identity }
            backend.configureTerminalTheme(style: themeStyle, for: tmuxName)
            await MainActor.run { [weak self, weak terminalView] in
                guard let self else { return }
                self.backingLaunchInFlight = false
                self.admissionLaunchSucceeded = true
                self.admissionPanePID = admissionPane.flatMap { Int32(exactly: $0.rootPID) }
                self.admissionProcessIdentity = paneIdentity
                if self.status == .closed { self.sessionRuntime.removeBackingSession(named: tmuxName) }
                self.onAgentRuntimeChanged?()
                guard let terminalView,
                      self.terminalClientGeneration == generation,
                      self.loadedTerminalView === terminalView,
                      !self.isImportedHistory, !self.isSuspended, self.status != .closed,
                      !terminalView.process.running else { return }
                self.isRestored = false
                self.trackedPaneIdentity = paneIdentity
                self.isProcessStarted = true
                self.attemptedBlankTerminalRecovery = false
                self.status = .running
                terminalView.beginInitialScreenSynchronization(restarting: true)
                terminalView.startProcess(
                    executable: "/usr/bin/env",
                    args: ["-u", "TMUX", "-u", "TMUX_PANE", backend.executableURL.path] + backend.attachArguments(for: tmuxName),
                    environment: self.terminalEnvironment(),
                    currentDirectory: self.cwd
                )
                self.touch()
                telemetry.recordDuration(
                    "terminal.start_client",
                    durationMS: PerformanceTelemetry.elapsedMS(since: startedAt),
                    sessionID: sessionID,
                    detail: "tmux=\(tmuxName) async"
                )
            }
        }
    }

    func refreshTerminalClient(immediately: Bool = false) {
        guard !isImportedHistory, loadedTerminalView?.process.running == true else { return }
        let tmuxBackend = tmuxBackend
        let tmuxSessionName = tmuxSessionName
        let sessionID = id
        let generation = terminalClientGeneration

        if immediately {
            let startedAt = DispatchTime.now()
            let telemetry = self.telemetry
            DispatchQueue.global(qos: .userInteractive).async { [weak self, telemetry] in
                tmuxBackend.refreshClients(attachedTo: tmuxSessionName)
                telemetry.recordDuration(
                    "tmux.refresh_clients",
                    durationMS: PerformanceTelemetry.elapsedMS(since: startedAt),
                    sessionID: sessionID,
                    detail: "tmux=\(tmuxSessionName) immediate"
                )
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.isImportedHistory,
                          self.terminalClientGeneration == generation,
                          let terminalView = self.loadedTerminalView,
                          terminalView.process.running else { return }
                    terminalView.requestFullRedraw()
                }
            }
            return
        }

        terminalRefreshTask?.cancel()
        terminalRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return }
            let startedAt = DispatchTime.now()
            await Task.detached(priority: .utility) {
                tmuxBackend.refreshClients(attachedTo: tmuxSessionName)
            }.value
            self?.telemetry.recordDuration(
                "tmux.refresh_clients",
                durationMS: PerformanceTelemetry.elapsedMS(since: startedAt),
                sessionID: sessionID,
                detail: "tmux=\(tmuxSessionName)"
            )
            guard let self,
                  !Task.isCancelled,
                  self.terminalClientGeneration == generation,
                  !self.isImportedHistory,
                  let terminalView = self.loadedTerminalView,
                  terminalView.process.running else {
                return
            }
            terminalView.requestFullRedraw()
            self.terminalRefreshTask = nil
        }
    }

    func scrollHistory(paneID: String, lines: Int, up: Bool, onScrollPosition: (@Sendable (Int) -> Void)? = nil) {
        tmuxBackend.scrollHistory(paneID: paneID, lines: lines, up: up, onScrollPosition: onScrollPosition)
    }

    func recoverBlankTerminalClientIfNeeded() {
        guard !isImportedHistory,
              !attemptedBlankTerminalRecovery,
              let terminalView = loadedTerminalView,
              terminalView.process.running,
              terminalView.hasVisibleText == false else {
            return
        }
        // `capture-pane` is a synchronous tmux subprocess (10s timeout). Running
        // it here used to block the main thread 0.5s after every switch. Capture
        // in the background; the reattach below only runs when the pane actually
        // has content the blank terminal missed (rare).
        let backend = tmuxBackend
        let tmuxName = tmuxSessionName
        let telemetry = telemetry
        let sessionID = id
        attemptedBlankTerminalRecovery = true
        let generation = terminalClientGeneration
        Task.detached(priority: .utility) { [weak self] in
            let capturedText = backend.captureCurrentVisibleText(paneID: tmuxName)
            guard capturedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                // Pane is genuinely empty — allow a later switch to retry once
                // it has content, matching the old synchronous semantics.
                await MainActor.run { [weak self] in
                    guard self?.terminalClientGeneration == generation else { return }
                    self?.attemptedBlankTerminalRecovery = false
                }
                return
            }
            await MainActor.run { [weak self] in
                guard let self,
                      self.terminalClientGeneration == generation,
                      !self.isImportedHistory,
                      self.loadedTerminalView?.process.running == true,
                      self.loadedTerminalView?.hasVisibleText == false else {
                    return
                }
                telemetry.recordDuration(
                    "terminal.blank_recovery",
                    durationMS: 1,
                    sessionID: sessionID,
                    detail: "tmux=\(tmuxName)"
                )
                self.reattachTerminalClient(resetBlankRecoveryAttempt: false)
            }
        }
    }

    func reattachTerminalClient(resetBlankRecoveryAttempt: Bool = true) {
        guard !isImportedHistory else { return }
        invalidateTerminalClientWork()
        isInactiveTerminalClientDetached = false
        let startedAt = DispatchTime.now()
        if terminalView.process.running {
            isDetachingTerminalClient = true
            terminalView.terminate()
        }
        isDetachingTerminalClient = false
        isProcessStarted = false
        isRestored = false
        // A reattached client rebuilds its local buffer from the live tmux pane.
        // An old SwiftTerm row no longer identifies the same content and would
        // visibly pull the viewport into stale history before it follows live
        // output again.
        terminalView.resetForNewProcess()
        startTerminalClient(resetBlankRecoveryAttempt: resetBlankRecoveryAttempt)
        telemetry.recordDuration(
            "terminal.reattach_client",
            durationMS: PerformanceTelemetry.elapsedMS(since: startedAt),
            sessionID: id,
            detail: "tmux=\(tmuxSessionName)"
        )
    }

    /// Starts a session whose tmux server disappeared while Banyan was stopped.
    /// The caller may supply a provider-specific resume command.
    func recoverFromMissingBackingSession(command recoveryCommand: String? = nil) {
        guard !isImportedHistory else { return }
        if let recoveryCommand, !recoveryCommand.isEmpty {
            command = recoveryCommand
        }
        needsRecovery = false
        isRestored = false
        reattachTerminalClient()
    }

    /// Recreates the backing tmux session without allocating or attaching a
    /// visible terminal client. Used for automatic launch recovery so every
    /// session resumes in the background while only the selected session is
    /// rendered by the UI.
    func recoverFromMissingBackingSessionInBackground(command recoveryCommand: String? = nil) {
        guard !isImportedHistory, !isProcessStarted else { return }
        if let recoveryCommand, !recoveryCommand.isEmpty {
            command = recoveryCommand
        }
        needsRecovery = false
        isRestored = false
        status = .running
        touch()
        startBackingSessionInBackground()
    }

    func startBackingSessionInBackground() {
        guard !backingLaunchInFlight else { return }
        if canReuseCompletedAgentPane {
            isProcessStarted = true
            onAgentBackendReady?()
            return
        }
        guard ensureProjectFolderAccess() else { return }
        guard requestAgentAdmission(retry: { [weak self] in self?.startBackgroundBackendIfNeeded() }) else { return }
        let runtime = sessionRuntime
        let request = launchRequest
        let backend = tmuxBackend
        backingLaunchInFlight = true
        admissionGeneration = UUID()
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try runtime.ensureBackingSession(request)
                let admissionPane = backend.primaryPaneSnapshot(named: request.sessionName)
                let identity = admissionPane.flatMap { AgentProcessSample.read(pid: Int32($0.rootPID))?.identity }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.backingLaunchInFlight = false
                    self.admissionLaunchSucceeded = true
                    self.admissionPanePID = admissionPane.flatMap { Int32(exactly: $0.rootPID) }
                    self.admissionProcessIdentity = identity
                    if self.status == .closed {
                        self.sessionRuntime.removeBackingSession(named: request.sessionName)
                        self.onAgentRuntimeChanged?()
                        return
                    }
                    self.trackedPaneIdentity = identity
                    self.isProcessStarted = true
                    self.onAgentRuntimeChanged?()
                    self.touch()
                    self.onAgentBackendReady?()
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.backingLaunchInFlight = false
                    self?.failToStart(error.localizedDescription)
                }
            }
        }
    }

    func restartBackingSession() {
        guard !isImportedHistory, !backingLaunchInFlight else { return }
        // A restart of already-running work keeps its existing slot.
        guard ensureProjectFolderAccess() else { return }
        guard requestAgentAdmission(purpose: .restart, retry: { [weak self] in self?.restartBackingSession() }) else { return }
        admissionGeneration = UUID()
        cancelDeepLifecycle()
        do { try prepareFrozenAgentForTeardown() }
        catch { freezeError = error.localizedDescription; onAgentRuntimeChanged?(); return }
        suspendTicket = nil
        deepRecoveryIsUncertain = false
        hasLoadedDeepSuspendTicket = false
        deepSuspendError = nil
        isDeepSuspended = false
        isDeepTerminating = false
        isDeepResuming = false
        admissionProviderIdentity = nil
        admissionConfirmedExitPID = nil
        trackedPaneIdentity = nil
        invalidateTerminalClientWork()
        if let terminalView = loadedTerminalView {
            if terminalView.process.running {
                isDetachingTerminalClient = true
            }
            terminalView.terminate()
        }
        isDetachingTerminalClient = false
        isProcessStarted = false
        isRestored = false
        do {
            try sessionRuntime.restartBackingSession(launchRequest)
        } catch {
            failToStart(error.localizedDescription)
            return
        }
        startTerminalClient(backingSessionAlreadyEnsured: true)
    }

    func attachAdmittedTerminalClientIfNeeded() {
        guard !isSuspended, status != .closed, isProcessStarted,
              let view = loadedTerminalView, !view.process.running,
              view.bounds.width > 80, view.bounds.height > 80 else { return }
        startTerminalClient(backingSessionAlreadyEnsured: true)
    }

    private func startTerminalClient(
        resetBlankRecoveryAttempt: Bool = true,
        backingSessionAlreadyEnsured: Bool = false
    ) {
        guard !backingLaunchInFlight else { return }
        guard ensureProjectFolderAccess() else { return }
        // Attaching an existing pane cannot start its old configured command.
        // In particular, the persistent host may now contain only a plain shell.
        let existingPane: Bool
        if backingSessionAlreadyEnsured { existingPane = true }
        else if case .present(let pane) = tmuxBackend.agentAdmissionPane(named: tmuxSessionName) { existingPane = !pane.isDead }
        else { existingPane = false }
        if !existingPane {
            guard requestAgentAdmission(retry: { [weak self] in self?.startBackgroundBackendIfNeeded() }) else { return }
            admissionGeneration = UUID()
        }
        // Set the server default before creating a new pane. Codex probes OSC
        // 10/11 during startup, before SwiftTerm has necessarily attached.
        tmuxBackend.configureTerminalTheme(style: pendingTheme.tmuxDefaultStyle, for: nil)
        if !backingSessionAlreadyEnsured {
            do {
                try sessionRuntime.ensureBackingSession(launchRequest)
            } catch {
                failToStart(error.localizedDescription)
                return
            }
        }
        tmuxBackend.configureTerminalTheme(style: pendingTheme.tmuxDefaultStyle, for: tmuxSessionName)
        trackPaneIdentityIfNeeded()
        admissionLaunchSucceeded = true
        admissionPanePID = tmuxBackend.primaryPaneSnapshot(named: tmuxSessionName).flatMap { Int32(exactly: $0.rootPID) }
        admissionProcessIdentity = trackedPaneIdentity
        onAgentRuntimeChanged?()
        isRestored = false
        isProcessStarted = true
        if resetBlankRecoveryAttempt {
            attemptedBlankTerminalRecovery = false
        }
        status = .running
        // A reattach may spend time ensuring tmux first; begin the quiet window
        // at the actual client launch so it only covers the pane redraw.
        terminalView.beginInitialScreenSynchronization(restarting: true)
        terminalView.startProcess(
            executable: "/usr/bin/env",
            args: ["-u", "TMUX", "-u", "TMUX_PANE", tmuxBackend.executableURL.path] + tmuxBackend.attachArguments(for: tmuxSessionName),
            environment: terminalEnvironment(),
            currentDirectory: cwd
        )
        touch()
    }

    func killBackingSession() {
        cancelDeepLifecycle()
        do { try prepareFrozenAgentForTeardown() }
        catch { freezeError = error.localizedDescription; return }
        freezeGeneration = UUID()
        trackedPaneIdentity = nil
        status = .closed
        isSuspended = false
        stopTerminalClient()
        agentAdmission?.cancel(id)
        sessionRuntime.removeBackingSession(named: tmuxSessionName)
        onAgentRuntimeChanged?()
        touch()
    }

    func stopTerminalClient() {
        invalidateTerminalClientWork()
        isInactiveTerminalClientDetached = false
        isDetachingTerminalClient = false
        loadedTerminalView?.terminate()
        isProcessStarted = false
        isRestored = false
    }

    func detachTerminalClient() {
        guard status != .closed else { return }
        invalidateTerminalClientWork()
        isInactiveTerminalClientDetached = false
        if let terminalView = loadedTerminalView, terminalView.process.running {
            isDetachingTerminalClient = true
            terminalView.terminate()
        }
        isProcessStarted = false
        isRestored = false
        touch()
    }

    /// Drop only the display client of a hidden session. Its tmux pane remains
    /// live and supervised, so agent status can still update in the sidebar.
    func detachInactiveTerminalClient() {
        guard !isImportedHistory, !isSuspended, status != .closed,
              let terminalView = loadedTerminalView, terminalView.process.running else { return }
        invalidateTerminalClientWork()
        isInactiveTerminalClientDetached = true
        isDetachingTerminalClient = true
        terminalView.terminate()
        telemetry.recordDuration("terminal.inactive_detach", durationMS: 1, sessionID: id)
    }

    /// Release the display and its buffers on the main actor. The caller removes
    /// its inactive container first. The tmux pane, agent, and observed status
    /// remain live; a revisit uses the existing inactive-client reattach path.
    func unloadTerminalView() {
        invalidateTerminalClientWork()
        guard let view = loadedTerminalView else { return }
        isInactiveTerminalClientDetached = isProcessStarted && !isSuspended && status != .closed
        view.cancelInitialScreenSynchronization()
        view.displayUpdatesEnabled = false
        view.processDelegate = nil
        view.onOutput = nil
        view.permitsInput = nil
        view.onCommittedInput = nil
        view.terminate()
        view.removeFromSuperview()
        _terminalView = nil
        isDetachingTerminalClient = false
        didRenderRestoredMessage = false
        appliedTheme = nil
        appliedFontFamily = nil
        appliedFontSize = nil
        attemptedBlankTerminalRecovery = false
        telemetry.recordDuration("terminal.view_unload", durationMS: 1, sessionID: id)
    }

    private func invalidateTerminalClientWork() {
        terminalClientGeneration = UUID()
        terminalRefreshTask?.cancel()
        terminalRefreshTask = nil
    }

    /// The backing tmux pane was never stopped, so reconnect directly without
    /// the synchronous ensure/probe path used for missing sessions.
    func resumeInactiveTerminalClientIfNeeded() {
        guard isInactiveTerminalClientDetached, !isSuspended, status != .closed else { return }
        let startedAt = DispatchTime.now()
        isInactiveTerminalClientDetached = false
        isDetachingTerminalClient = false
        terminalView.resetForNewProcess()
        terminalView.beginInitialScreenSynchronization(restarting: true)
        terminalView.startProcess(
            executable: "/usr/bin/env",
            args: ["-u", "TMUX", "-u", "TMUX_PANE", tmuxBackend.executableURL.path] + tmuxBackend.attachArguments(for: tmuxSessionName),
            environment: terminalEnvironment(),
            currentDirectory: cwd
        )
        telemetry.recordDuration(
            "terminal.inactive_reattach",
            durationMS: PerformanceTelemetry.elapsedMS(since: startedAt),
            sessionID: id
        )
    }

    fileprivate func restoredMessage() -> String {
        let commandText = command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "default login shell" : command
        let recoveryText = needsRecovery
            ? "The tmux session disappeared while Banyan was stopped. Use Recover to recreate it."
            : "The tmux session is not currently attached in Banyan. Use Attach to reconnect."
        return [
            "Restored Banyan session metadata.",
            "",
            "Title: \(title)",
            "Directory: \(cwd)",
            "Command: \(commandText)",
            "tmux: \(tmuxSessionName)",
            "",
            recoveryText,
            "Use Remove to kill the persisted session entry.",
            ""
        ].joined(separator: "\r\n")
    }

    fileprivate func failToStart(_ message: String) {
        isRestored = true
        isProcessStarted = false
        status = .failed
        feedOrQueue("Banyan could not attach this session.\r\n\r\n\(message)\r\n")
        onStatusSignal?(status)
        onAgentRuntimeChanged?()
        touch()
    }

    private func ensureProjectFolderAccess() -> Bool {
        switch ProjectFolderAccess.evaluate(for: cwd) {
        case .available:
            return true
        case .missingFolder:
            failToStart("Project folder no longer exists: \(cwd). Re-create the worktree or close this session.")
            return false
        case .permissionDenied:
            guard ProjectFolderAccess.requestIfNeeded(for: cwd) else {
                failToStart("Banyan needs access to the project folder before it can start this session. Select the folder when prompted and try again.")
                return false
            }
            return true
        }
    }

    func terminalEnvironment() -> [String] {
        var environment = Terminal.getEnvironmentVariables(termName: TmuxBackend.attachTermName, trueColor: true)
        let inherited = self.environment
        for key in ["PATH", "SHELL", "TMPDIR", "SSH_AUTH_SOCK", "NO_COLOR"] {
            if let value = inherited[key] {
                environment.append("\(key)=\(value)")
            }
        }
        environment.append("CLICOLOR=1")
        return environment
    }
}
