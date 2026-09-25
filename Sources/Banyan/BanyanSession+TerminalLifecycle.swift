import AppKit
import BanyanCore
import Foundation
import SwiftTerm

extension BanyanSession {
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
        guard !isImportedHistory, !isSuspended else { return }
        guard loadedTerminalView?.process.running != true else { return }
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
        isDetachingTerminalClient = false
        let runtime = sessionRuntime
        let request = launchRequest
        let backend = tmuxBackend
        let themeStyle = pendingTheme.tmuxDefaultStyle
        let telemetry = telemetry
        let sessionID = id
        let tmuxName = tmuxSessionName
        let startedAt = DispatchTime.now()
        Task.detached(priority: .userInitiated) { [weak self] in
            backend.configureTerminalTheme(style: themeStyle, for: nil)
            do {
                try runtime.ensureBackingSession(request)
            } catch {
                let message = error.localizedDescription
                await MainActor.run { [weak self] in
                    self?.failToStart(message)
                }
                return
            }
            backend.configureTerminalTheme(style: themeStyle, for: tmuxName)
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard !self.isImportedHistory, !self.isSuspended else { return }
                guard self.loadedTerminalView?.process.running != true else { return }
                self.isRestored = false
                self.isProcessStarted = true
                self.attemptedBlankTerminalRecovery = false
                self.status = .running
                self.terminalView.beginInitialScreenSynchronization(restarting: true)
                self.terminalView.startProcess(
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

    /// Start the tmux backing (and its launch command) without attaching a visible
    /// terminal client, so a session spawned in the background actually runs without
    /// stealing selection/focus. When the session is later selected, `start()` attaches
    /// the visible client to this already-running tmux session (`ensureSession` is idempotent).
    func startBackgroundBackendIfNeeded() {
        guard !isImportedHistory, status != .closed, !isSuspended else { return }
        // Deliberately does not attach a visible client, so it must not create a
        // terminal either — an absent one is by definition not running.
        guard !isProcessStarted, loadedTerminalView?.process.running != true else { return }
        // Optimistically mark running so the sidebar updates immediately; the actual
        // tmux work (subprocess spawns) runs off the main thread to avoid freezing the
        // UI while a session is created via banyanctl.
        isRestored = false
        status = .running
        touch()
        startBackingSessionInBackground()
    }

    func refreshTerminalClient(immediately: Bool = false) {
        guard !isImportedHistory, loadedTerminalView?.process.running == true else { return }
        let tmuxBackend = tmuxBackend
        let tmuxSessionName = tmuxSessionName
        let sessionID = id

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
        Task.detached(priority: .utility) { [weak self] in
            let capturedText = backend.captureCurrentVisibleText(paneID: tmuxName)
            guard capturedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                // Pane is genuinely empty — allow a later switch to retry once
                // it has content, matching the old synchronous semantics.
                await MainActor.run { [weak self] in
                    self?.attemptedBlankTerminalRecovery = false
                }
                return
            }
            await MainActor.run { [weak self] in
                guard let self,
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
        isInactiveTerminalClientDetached = false
        let startedAt = DispatchTime.now()
        terminalRefreshTask?.cancel()
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

    private func startBackingSessionInBackground() {
        guard ensureProjectFolderAccess() else { return }
        let runtime = sessionRuntime
        let request = launchRequest
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try runtime.ensureBackingSession(request)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isProcessStarted = true
                    self.touch()
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.failToStart(error.localizedDescription)
                }
            }
        }
    }

    func restartBackingSession() {
        guard !isImportedHistory else { return }
        terminalRefreshTask?.cancel()
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

    private func startTerminalClient(
        resetBlankRecoveryAttempt: Bool = true,
        backingSessionAlreadyEnsured: Bool = false
    ) {
        guard ensureProjectFolderAccess() else { return }
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

    func apply(theme: TerminalTheme, fontFamily: String? = nil, fontSize: Double = 13, force: Bool = false) {
        guard force || appliedTheme != theme || appliedFontFamily != fontFamily || appliedFontSize != fontSize else {
            return
        }
        pendingTheme = theme
        pendingFontFamily = fontFamily
        pendingFontSize = fontSize
        // A theme change for a session with no terminal yet is just bookkeeping;
        // `makeTerminalView` applies it if and when one is created.
        guard let view = loadedTerminalView else { return }
        theme.apply(to: view, fontFamily: fontFamily, fontSize: fontSize)
        tmuxBackend.configureTerminalTheme(style: theme.tmuxDefaultStyle, for: tmuxSessionName)
        appliedTheme = theme
        appliedFontFamily = fontFamily
        appliedFontSize = fontSize
        view.requestFullRedraw()
    }

    /// Switching renderers on a live session rebuilds its drawing surface, so
    /// it only touches sessions that already have a terminal; the rest resolve
    /// the preference in `makeTerminalView`.
    func apply(renderer: TerminalRendererPreference) {
        loadedTerminalView?.rendererPreference = renderer
    }

    func terminate(markClosed: Bool = true) {
        stopTerminalClient()
        if markClosed {
            status = .closed
            // A closed session is over, not parked. Leaving the flag set would
            // badge a history row and carry parking into a later reopen.
            isSuspended = false
        }
        touch()
    }

    func killBackingSession() {
        status = .closed
        isSuspended = false
        stopTerminalClient()
        sessionRuntime.removeBackingSession(named: tmuxSessionName)
        touch()
    }

    private func stopTerminalClient() {
        terminalRefreshTask?.cancel()
        isInactiveTerminalClientDetached = false
        isDetachingTerminalClient = false
        loadedTerminalView?.terminate()
        isProcessStarted = false
        isRestored = false
    }

    func detachTerminalClient() {
        guard status != .closed else { return }
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
        terminalRefreshTask?.cancel()
        isInactiveTerminalClientDetached = true
        isDetachingTerminalClient = true
        terminalView.terminate()
        telemetry.recordDuration("terminal.inactive_detach", durationMS: 1, sessionID: id)
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

    /// Parks the session: Banyan stops observing and rendering it, while its tmux
    /// session and agent process keep running untouched. Nothing is torn down, so
    /// `resume()` is lossless.
    ///
    /// `status` is deliberately left alone. It still describes the agent, which is
    /// still doing whatever it was doing; overwriting it here would lose exactly
    /// the state a resume is supposed to bring back.
    func suspend() {
        guard !isImportedHistory, status != .closed, !isSuspended else { return }
        isSuspended = true
        // Drops the SwiftTerm client only. Reattaching later rebuilds the buffer
        // from the live pane, so no scrollback is lost.
        detachTerminalClient()
    }

    /// Returns the session to Banyan's working set.
    ///
    /// Nothing observed this session while it was parked, so a tmux server that
    /// exited meanwhile is only discovered here. One `has-session` probe settles
    /// whether the row re-enters supervision or needs recovery.
    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        if tmuxBackend.hasSession(named: tmuxSessionName) {
            // The backing session ran the whole time, so rejoin the supervisor
            // tick immediately rather than waiting for a visible client to attach.
            isProcessStarted = true
            // This probe outranks anything the liveness sweep concluded earlier.
            needsRecovery = false
        } else {
            // Same shape as a session restored without its tmux server: persisted
            // metadata, nothing behind it. `needsManualAttach` reads all three
            // fields, so the recovery banner needs `isRestored` set here too.
            isProcessStarted = false
            isRestored = true
            needsRecovery = true
        }
        touch()
    }

    func touch() {
        // `updatedAt` feeds sidebar ordering and the sidebar/history cache
        // hashes, which scan every row (~3000 with closed history). Bumping it
        // on every observation and output chunk kept those caches permanently
        // cold: each keystroke re-evaluates the menu bar, which rebuilds the
        // full grouping. Recency at 2s granularity is plenty for
        // human-readable ordering and resume heuristics.
        let now = Date()
        if now.timeIntervalSince(updatedAt) >= 2 {
            updatedAt = now
        }
        onDidChange?()
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

    fileprivate func terminalEnvironment() -> [String] {
        var environment = Terminal.getEnvironmentVariables(termName: TmuxBackend.attachTermName, trueColor: true)
        let inherited = self.environment
        for key in ["PATH", "SHELL", "TMPDIR", "SSH_AUTH_SOCK"] {
            if let value = inherited[key] {
                environment.append("\(key)=\(value)")
            }
        }
        environment.append("CLICOLOR=1")
        environment.append("CLICOLOR_FORCE=1")
        environment.append("FORCE_COLOR=3")
        return environment
    }
}
