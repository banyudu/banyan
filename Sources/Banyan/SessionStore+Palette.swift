import BanyanCore
import Foundation
import AppKit
import SwiftUI

extension SessionStore {
    func requestCommandPalette() {
        commandPaletteRequestID = UUID()
    }

    @discardableResult
    func runTerminalSlashCommand(_ command: TerminalSlashCommand, from terminal: TerminalSession) -> Bool {
        guard selectedSession === terminal, terminal.acceptsTerminalSlashCommand else { return false }
        switch command {
        case .new:
            _ = spawnPaletteAgentSession()
        case .newRoot:
            _ = spawnPaletteAgentSessionInProjectRoot()
        case .newTerminal:
            _ = spawnTerminalSiblingSession()
        case .scratch:
            openScratchTerminal()
        case .find:
            showFindInSelectedSession()
        case .rename:
            selection.requestRenameSelectedSession()
        case .close:
            handleCloseCommand(in: NSApp.keyWindow)
        case .sessions:
            sidebarMode = .sessions
        case .next:
            selectNextSession()
        case .previous:
            selectPreviousSession()
        case .nextAttention:
            selectNextSessionNeedingAttention()
        case .previousAttention:
            selectPreviousSessionNeedingAttention()
        case .workable:
            selectNextWorkableSession()
        }
        return true
    }

    /// The session a palette command should nest under, or nil for a top-level
    /// session. `root` is deliberately not "sibling of the selected session":
    /// the app inherits `BANYAN_SESSION_ID` from the pane it was launched in,
    /// so anything short of an explicit nil keeps landing in that subtree.
    private func paletteParentSessionID(for parent: PaletteCommand.Parent) -> String? {
        switch parent {
        case .root: return nil
        case .current: return selectedSession?.id
        }
    }

    /// Environment edits for an out-of-process helper (`~/bin/workit`,
    /// `~/bin/banyan-worktree`, a palette command), so it resolves the intended
    /// parent instead of the session the Banyan app itself happens to run in.
    ///
    /// The identity keys always go: `banyanctl` falls back to the enclosing
    /// tmux session (`enclosingTmuxSessionID`), so `BANYAN_SESSION_ID` alone
    /// is not enough — `TMUX` / `TMUX_PANE` have to go with it when no
    /// explicit parent is being set.
    nonisolated static func helperSpawnEnvironmentEdits(
        parentSessionID: String?
    ) -> (removeKeys: Set<String>, overrides: [String: String]) {
        var removeKeys: Set<String> = [
            BanyanSessionEnvironment.sessionIDKey,
            BanyanSessionEnvironment.parentSessionIDKey
        ]
        var overrides: [String: String] = [:]
        if let parentSessionID {
            // An explicit parent wins over both the env fallback and the tmux
            // fallback, so `TMUX` can stay and the command keeps its context.
            overrides[BanyanSessionEnvironment.parentSessionIDKey] = parentSessionID
        } else {
            removeKeys.insert("TMUX")
            removeKeys.insert("TMUX_PANE")
        }
        return (removeKeys, overrides)
    }

    /// Run a user-configured palette command. `target` is the Linear/GitHub
    /// ID detected in the palette query (or the selected session's issue).
    ///
    /// Also the path an approved inbound suggestion takes, as a synthetic
    /// command: the spawn, the background runner, the log file and the result
    /// banner are the same either way.
    ///
    /// The run is recorded in `paletteCommandRun` either way. It deliberately no
    /// longer writes to `linearIssueListLoadState`: that state belongs to the
    /// Linear issue list, and it is only rendered inside the Linear sidebar, so
    /// a palette-command failure routed through it was invisible — and wiped by
    /// the list's own refresh the moment the user went looking for it.
    func runPaletteCommand(
        _ paletteCommand: PaletteCommand,
        target: String?,
        query: String? = nil,
        cwd overrideCWD: String? = nil,
        select: Bool = true
    ) {
        // The palette's agent picker only reaches a command that opts in with
        // `{{agent}}` / `{{agentFlag}}`; nil (Auto) expands both away.
        let agent = paletteAgentLaunch?.id
        let expandedCommand = paletteCommand.expandedCommand(target: target, query: query, agent: agent)
        let expandedTitle = paletteCommand.expandedTitle(target: target, query: query, agent: agent)
        guard !expandedCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let parentSessionID = paletteParentSessionID(for: paletteCommand.parent)
        // An inbound suggestion may name its own directory; a palette command
        // never does, and keeps the selected session's.
        let cwd = overrideCWD ?? selectedSession?.cwd ?? homeDirectory
        let startedAt = Date()
        switch paletteCommand.run {
        case .session:
            let session = spawn(
                title: expandedTitle,
                cwd: cwd,
                command: expandedCommand,
                parentSessionID: parentSessionID,
                select: select
            )
            paletteCommandRun = PaletteCommandRun(
                commandID: paletteCommand.id,
                title: expandedTitle,
                command: expandedCommand,
                startedAt: startedAt,
                status: .launchedSession(id: session.id),
                finishedAt: startedAt
            )
        case .background:
            let logURL = PaletteCommandRunLog.fileURL(
                host: host,
                commandID: paletteCommand.id,
                startedAt: startedAt
            )
            let run = PaletteCommandRun(
                commandID: paletteCommand.id,
                title: expandedTitle,
                command: expandedCommand,
                startedAt: startedAt,
                status: .running,
                logURL: logURL
            )
            paletteCommandRun = run
            let runID = run.id
            let environment = self.environment
            let homeDirectory = self.homeDirectory
            Task.detached(priority: .userInitiated) { [environment, homeDirectory] in
                let outcome = Self.runPaletteBackgroundCommand(
                    shellCommand: expandedCommand,
                    cwd: cwd,
                    homeDirectory: homeDirectory,
                    environment: environment,
                    parentSessionID: parentSessionID,
                    logURL: logURL
                )
                await MainActor.run { [weak self] in
                    self?.finishPaletteCommandRun(runID: runID, outcome: outcome)
                }
            }
        }
    }

    /// Records a finished background run. A run that has already been replaced
    /// (the user launched another command meanwhile) is dropped rather than
    /// overwriting the newer run's banner.
    private func finishPaletteCommandRun(runID: UUID, outcome: PaletteCommandOutcome) {
        guard var run = paletteCommandRun, run.id == runID else { return }
        run.finishedAt = Date()
        switch outcome {
        case .finished(let exitCode, let output):
            run.status = exitCode == 0 ? .succeeded : .failed(exitCode: exitCode)
            run.outputTail = output.text
            run.isOutputTruncated = output.isTruncated
        case .couldNotStart(let message):
            run.status = .couldNotStart
            run.outputTail = message
            run.isOutputTruncated = false
        }
        paletteCommandRun = run
        if run.status == .succeeded {
            runHistoryImport()
        }
    }

    /// Clears the palette-command banner. The run's log file stays on disk.
    func dismissPaletteCommandRun() {
        paletteCommandRun = nil
    }

    // MARK: - Inbound suggestions

    /// Offers an inbound suggestion the pending slot, and republishes whatever
    /// the inbox holds afterwards — an offer that is refused can still have
    /// cleared an expired banner on its way through.
    func offerSuggestion(_ suggestion: InboundSuggestion) -> SuggestionInbox.Outcome {
        let outcome = suggestionInbox.offer(suggestion)
        pendingSuggestion = suggestionInbox.pending
        return outcome
    }

    /// Runs the pending suggestion, through exactly the path a palette command
    /// takes: the same spawn, the same background runner, the same log file and
    /// the same result banner. The suggestion channel adds the human gate in
    /// front of that path and nothing behind it.
    func approvePendingSuggestion() {
        guard let suggestion = pendingSuggestion else { return }
        suggestionInbox.resolve(id: suggestion.id)
        pendingSuggestion = suggestionInbox.pending
        runPaletteCommand(
            Self.paletteCommand(for: suggestion),
            target: suggestion.target,
            cwd: suggestion.cwd,
            // A suggestion is answered in passing, not as a deliberate context
            // switch, so approving one must not yank the user out of whatever
            // they were reading. This is the same rule an inbound `/spawn`
            // follows: take focus only when there is nothing to take it from,
            // which keeps the detail pane from sitting empty.
            select: selectedSessionID == nil
        )
    }

    /// Declines the pending suggestion. Its key stays suppressed for the rest of
    /// its TTL, so the picker that raised it does not raise it again on its next
    /// tick.
    func dismissPendingSuggestion() {
        guard let suggestion = pendingSuggestion else { return }
        suggestionInbox.resolve(id: suggestion.id)
        pendingSuggestion = suggestionInbox.pending
    }

    /// The synthetic palette command an approved suggestion runs as.
    ///
    /// The id is derived from the suggestion key so the run's log file is named
    /// after the nudge that caused it. `parent` is always `.root`: an
    /// out-of-process suggester has no view of what is selected, and a session
    /// opened from a nudge belongs at the top level.
    nonisolated static func paletteCommand(for suggestion: InboundSuggestion) -> PaletteCommand {
        PaletteCommand(
            id: "suggestion.\(SessionIdentityPolicy.sanitizedID(suggestion.key))",
            title: suggestion.title,
            command: suggestion.command,
            run: suggestion.run,
            parent: .root
        )
    }

    /// Runs one `run: background` palette command. Internal rather than private
    /// so tests can drive the real spawn (output capture, exit status, log file)
    /// without a full `SessionStore`.
    nonisolated static func runPaletteBackgroundCommand(
        shellCommand: String,
        cwd: String,
        homeDirectory: String,
        environment: [String: String],
        parentSessionID: String?,
        logURL: URL
    ) -> PaletteCommandOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", shellCommand]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let spawnEdits = helperSpawnEnvironmentEdits(parentSessionID: parentSessionID)
        process.environment = AppProcessEnvironment.make(
            base: environment,
            shellEnvironment: AppProcessEnvironment.shellEnvironment(environment: environment),
            pathAdditions: [
            "\(homeDirectory)/bin",
            "\(homeDirectory)/.bun/bin",
            "\(homeDirectory)/.local/bin",
            "\(homeDirectory)/.cargo/bin",
            "\(homeDirectory)/go/bin",
            "\(homeDirectory)/.nix-profile/bin",
            "/nix/var/nix/profiles/default/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin"
        ],
            removeKeys: spawnEdits.removeKeys,
            overrides: spawnEdits.overrides
        )
        // A GUI app has no usable stdin. Inheriting it can park a command on a
        // read that never returns, and a closed descriptor makes `Process.run()`
        // throw before the command ever starts. Palette commands are configured
        // with their arguments; they do not read prompts from a terminal.
        process.standardInput = FileHandle.nullDevice

        // Both streams go to one file. A pipe would need a concurrent drain to
        // keep a chatty command from filling the buffer and deadlocking, and the
        // file is what the user can read after the banner is gone.
        let logHandle: FileHandle
        do {
            try FileManager.default.createDirectory(
                at: logURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            guard let handle = try? FileHandle(forWritingTo: logURL) else {
                return .couldNotStart("Unable to open the command log at \(logURL.path)")
            }
            logHandle = handle
        } catch {
            return .couldNotStart(
                "Unable to open the command log at \(logURL.path): \(error.localizedDescription)"
            )
        }
        process.standardOutput = logHandle
        process.standardError = logHandle

        do {
            try process.run()
        } catch {
            try? logHandle.close()
            return .couldNotStart("Unable to start custom command: \(error.localizedDescription)")
        }

        process.waitUntilExit()
        try? logHandle.close()
        return .finished(
            exitCode: process.terminationStatus,
            output: PaletteCommandRunLog.tail(of: logURL)
        )
    }
}
