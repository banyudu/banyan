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
        guard !isImportedHistory else { return }
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

    /// Start the tmux backing (and its launch command) without attaching a visible
    /// terminal client, so a session spawned in the background actually runs without
    /// stealing selection/focus. When the session is later selected, `start()` attaches
    /// the visible client to this already-running tmux session (`ensureSession` is idempotent).
    func startBackgroundBackendIfNeeded() {
        guard !isImportedHistory, status != .closed else { return }
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
                    terminalView.needsDisplay = true
                    terminalView.setNeedsDisplay(terminalView.bounds)
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
            terminalView.needsDisplay = true
            terminalView.setNeedsDisplay(terminalView.bounds)
            self.terminalRefreshTask = nil
        }
    }

    func scrollHistory(paneID: String, lines: Int, up: Bool) {
        tmuxBackend.scrollHistory(paneID: paneID, lines: lines, up: up)
    }

    func recoverBlankTerminalClientIfNeeded() {
        guard !isImportedHistory,
              !attemptedBlankTerminalRecovery,
              let terminalView = loadedTerminalView,
              terminalView.process.running,
              terminalView.hasVisibleText == false else {
            return
        }
        let capturedText = tmuxBackend.captureCurrentVisibleText(paneID: tmuxSessionName)
        guard capturedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return
        }
        telemetry.recordDuration(
            "terminal.blank_recovery",
            durationMS: 1,
            sessionID: id,
            detail: "tmux=\(tmuxSessionName)"
        )
        attemptedBlankTerminalRecovery = true
        reattachTerminalClient(resetBlankRecoveryAttempt: false)
    }

    func reattachTerminalClient(resetBlankRecoveryAttempt: Bool = true) {
        guard !isImportedHistory else { return }
        let startedAt = DispatchTime.now()
        terminalRefreshTask?.cancel()
        terminalView.preserveScrollPosition()
        if terminalView.process.running {
            isDetachingTerminalClient = true
            terminalView.terminate()
        }
        isDetachingTerminalClient = false
        isProcessStarted = false
        isRestored = false
        terminalView.resetForNewProcess(preserveScrollPosition: true)
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
        terminalView.startProcess(
            executable: "/usr/bin/env",
            args: ["-u", "TMUX", "-u", "TMUX_PANE", tmuxBackend.executableURL.path] + tmuxBackend.attachArguments(for: tmuxSessionName),
            environment: terminalEnvironment(),
            currentDirectory: cwd
        )
        touch()
    }

    func apply(theme: TerminalTheme, fontFamily: String? = nil, fontSize: Double = 13) {
        guard appliedTheme != theme || appliedFontFamily != fontFamily || appliedFontSize != fontSize else {
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
        view.needsDisplay = true
    }
    func terminate(markClosed: Bool = true) {
        stopTerminalClient()
        if markClosed {
            status = .closed
        }
        touch()
    }

    func killBackingSession() {
        status = .closed
        stopTerminalClient()
        sessionRuntime.removeBackingSession(named: tmuxSessionName)
        touch()
    }

    private func stopTerminalClient() {
        terminalRefreshTask?.cancel()
        isDetachingTerminalClient = false
        loadedTerminalView?.terminate()
        isProcessStarted = false
        isRestored = false
    }

    func detachTerminalClient() {
        guard status != .closed else { return }
        if let terminalView = loadedTerminalView, terminalView.process.running {
            isDetachingTerminalClient = true
            terminalView.terminate()
        }
        isProcessStarted = false
        isRestored = false
        touch()
    }

    func touch() {
        updatedAt = Date()
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

    fileprivate func terminalEnvironment() -> [String] {
        var environment = Terminal.getEnvironmentVariables(termName: "xterm-256color", trueColor: true)
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
