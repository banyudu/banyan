import BanyanCore
import Foundation
import AppKit
import SwiftUI

extension SessionStore {
    func respawn(id: String) throws {
        guard let session = sessions.first(where: { $0.id == id }) else {
            throw ControlError.notFound(id)
        }
        session.agentLaunchQueue = nil
        unparkForAttach(session)
        // The daemon kept a closed puck session whole, so reopening it is only
        // a matter of following it again.
        if let native = session as? CodexSession {
            native.reopen()
            selectedSessionID = id
            saveSessions()
            return
        }
        if let session = session as? PuckSession {
            session.reopen()
            noteBackgroundPuckSessionOpened(id)
            selectedSessionID = id
            saveSessions()
            syncPuckSessions()
            return
        }
        historyResumeErrors.removeValue(forKey: id)
        // A worktree deleted after its branch merged leaves the session pointing
        // at nothing, and every attach re-runs the launch command in a directory
        // that is gone. Restore the worktree first and continue the attach from
        // the callback, so asking to attach is all the user has to do.
        if recoverWorktreeThenRespawn(id: id, session: session) {
            return
        }
        // A closed session had its tmux backing killed, so reattaching would
        // rerun the original launch command from scratch. For codex/claude
        // sessions whose underlying agent session we resolved, rebuild the
        // command as a resume so prior context is restored instead of replayed.
        //
        // Sessions closed before the live transcript match ran — or persisted by
        // an older build — have no `agentSessionID`. Try to recover it from the
        // imported history now so those still resume instead of replaying.
        if SessionRecoveryPolicy.requiresDeepHistoryRecovery(
            status: session.status,
            provider: session.agentProvider,
            agentSessionID: session.agentSessionID
        ), !recoverAgentSessionID(for: session) {
            recoverAgentSessionIDAndRespawn(id: id)
            return
        }
        try respawnAfterHistoryRecovery(id: id)
    }

    func recover(id: String, select: Bool = true) throws {
        guard let session = sessions.first(where: { $0.id == id && $0.needsRecovery }) as? TerminalSession else {
            throw ControlError.notFound(id)
        }
        unparkForAttach(session)
        if recoverWorktreeThenRespawn(id: id, session: session, continuation: { store in
            try? store.recover(id: id, select: select)
        }) {
            return
        }

        // Opencode sessions persisted before resume support never captured an
        // `agentSessionID` live. Resolve it now so Recover resumes instead of
        // starting a blank session. `latestImportedHistory` is in-memory and
        // fast; the SQLite fallback covers rows beyond the bounded import.
        if session.agentSessionID == nil,
           let provider = session.agentProvider,
           provider.isOpencodeBacked {
            if !recoverAgentSessionID(for: session) {
                resolveOpencodeAgentSessionID(for: session)
            }
        }

        let recoveryCommand: String?
        do {
            recoveryCommand = try canonicalAgentResumeCommand(for: session)
        } catch {
            historyResumeErrors[id] = error.localizedDescription
            throw error
        }

        guard session.agentProvider == nil || recoveryCommand?.isEmpty == false else {
            let message = SessionRecoveryPolicy.missingResumeMessage(provider: session.agentProvider)
            historyResumeErrors[id] = message
            throw ControlError.badRequest(message)
        }
        historyResumeErrors.removeValue(forKey: id)
        session.recoverFromMissingBackingSessionInBackground(command: recoveryCommand)
        if select {
            selectedSessionID = id
        }
        saveSessions()
    }

    /// Synchronous opencode lookup for Recover. The `session` table is tiny
    /// (~1k rows) and the query is one indexed-ish scan, so this is safe on the
    /// main thread for a user-initiated action. Uses the same cwd + timestamp
    /// windows as the live matcher.
    private func resolveOpencodeAgentSessionID(for session: BanyanSession) {
        let candidates = OpenCodeHistory.resumeCandidates(
            homeDirectory: URL(fileURLWithPath: homeDirectory),
            cwd: session.cwd
        )
        guard let match = AgentSessionMatcher.bestHistoryResumeMatch(
            sessionCWD: session.cwd,
            sessionCreatedAt: session.createdAt,
            sessionUpdatedAt: session.updatedAt,
            sessionResetAt: session.lastConversationResetAt,
            provider: session.agentProvider,
            in: candidates
        ) else {
            return
        }
        session.markAgentSessionID(match.sourceID)
    }

    func recoverAll(selectRecoveredSession: Bool = true) {
        for session in recoverySessions {
            try? recover(id: session.id, select: selectRecoveredSession)
        }
    }

    /// Recreates exact-ID agent sessions after a reboot without waiting for the
    /// user to click Recover. Folder authorization is deliberately evaluated
    /// before recovery: `recover` can present an `NSOpenPanel` for a protected
    /// folder, and doing that during window restoration can deadlock the app.
    /// A denied/missing folder therefore keeps its row in the manual Recover
    /// banner instead of prompting at launch.
    @discardableResult
    func autoRecoverRestoredAgentSessionsIfNeeded() -> [String] {
        guard !didAttemptStartupAgentRecovery else { return [] }
        didAttemptStartupAgentRecovery = true

        var recoveredIDs: [String] = []
        var folderAccessByCWD: [String: ProjectFolderAccess.Result] = [:]
        for session in terminalSessions where session.needsRecovery
            && !session.isImportedHistory
            && !session.isSuspended {
            guard SessionRecoveryPolicy.allowsAutomaticBackendRecovery(
                status: session.status,
                provider: session.agentProvider,
                agentSessionID: session.agentSessionID
            ) else { continue }

            let access = folderAccessByCWD[session.cwd] ?? ProjectFolderAccess.evaluate(for: session.cwd)
            folderAccessByCWD[session.cwd] = access
            guard access == .available else { continue }

            do {
                try recover(id: session.id, select: false)
                recoveredIDs.append(session.id)
            } catch {
                // `recover` publishes the actionable resume error next to the
                // row. Keep this launch pass going for the other sessions.
            }
        }
        return recoveredIDs
    }

    @discardableResult
    func openShellForClosedSession(id: String) throws -> BanyanSession {
        guard let session = sessions.first(where: { $0.id == id && $0.status == .closed }) else {
            throw ControlError.notFound(id)
        }
        return spawn(
            title: "zsh",
            cwd: session.cwd,
            command: HostShell.loginCommand(environment: environment)
        )
    }

    /// Reopen a closed codex/claude session, but first write a trimmed copy of
    /// its transcript (stale tool output cleared) and resume that instead — so the
    /// continued session replays far fewer input tokens per turn. Falls back to a
    /// normal full `respawn` whenever there's nothing worth trimming or the
    /// transcript can't be prepared. The original transcript is never modified.
    func respawnTrimmed(id: String) {
        guard let session = sessions.first(where: { $0.id == id }) as? TerminalSession else {
            try? respawn(id: id)
            return
        }
        if session.agentSessionID == nil {
            recoverAgentSessionID(for: session)
        }
        guard session.status == .closed,
              let provider = session.agentProvider,
              [.codex, .claude].contains(provider),
              let sourceID = session.agentSessionID, !sourceID.isEmpty else {
            try? respawn(id: id)
            return
        }
        let cwd = session.cwd
        let resetAt = session.lastConversationResetAt
        let historyBackend = historyBackend
        Task.detached(priority: .userInitiated) {
            let plan = SessionResumePolicy.plan(
                provider: provider,
                sourceID: sourceID,
                cwd: cwd,
                prompt: nil,
                transcriptURL: nil,
                trimmed: true,
                history: historyBackend
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard let session = self.sessions.first(where: { $0.id == id }) as? TerminalSession,
                      session.agentSessionID == sourceID, session.lastConversationResetAt == resetAt,
                      session.status == .closed else { return }
                guard let plan else {
                    try? self.respawn(id: id)
                    return
                }
                do {
                    session.command = try self.canonicalResumeCommand(
                        provider: provider,
                        sourceID: plan.sourceID,
                        cwd: cwd,
                        directCommand: plan.command,
                        previousCommand: session.command
                    )
                } catch {
                    self.historyResumeErrors[id] = error.localizedDescription
                    return
                }
                session.markAgentSessionID(plan.sourceID)
                session.reattachTerminalClient()
                self.selectedSessionID = id
                self.saveSessions()
            }
        }
    }

    /// Best-effort recovery of a closed session's underlying agent session UUID
    /// from the most recently imported transcript history, matched by provider,
    /// cwd, and creation/reset time. Used at reopen for sessions that never had
    /// `agentSessionID` resolved while live (closed too early, pinned title, or
    /// persisted by an older build) so they can still resume rather than replay.
    @discardableResult
    private func recoverAgentSessionID(for session: BanyanSession) -> Bool {
        guard session.matchesAgentTranscripts,
              let match = AgentSessionMatcher.bestHistoryResumeMatch(
            sessionCWD: session.cwd,
            sessionCreatedAt: session.createdAt,
            sessionUpdatedAt: session.updatedAt,
            sessionResetAt: session.lastConversationResetAt,
            provider: session.agentProvider,
            in: latestImportedHistory
        ) else {
            return false
        }
        // See refreshLiveAgentTitles: never downgrade a refined opencode-backed
        // identity (`.muse`, `.deepseek`, …) to generic `.opencode`.
        if !(match.provider.isOpencodeBacked && session.agentProvider?.isOpencodeBacked == true) {
            session.markDetectedAgentProvider(match.provider)
        }
        session.markAgentSessionID(match.sourceID)
        return true
    }

    /// Restores a session's deleted worktree, then resumes the attach it
    /// interrupted. Returns true when recovery started and the caller should
    /// stand down; the continuation re-enters the original path once the
    /// directory exists.
    ///
    /// Git work runs off the main actor: `worktree add` on a large repository
    /// takes seconds, and blocking here would freeze the window mid-click.
    @discardableResult
    private func recoverWorktreeThenRespawn(
        id: String,
        session: BanyanSession,
        continuation: (@MainActor (SessionStore) -> Void)? = nil
    ) -> Bool {
        guard WorktreeRecovery.isRecoverable(cwd: session.cwd) else { return false }
        guard pendingWorktreeRecoveryIDs.insert(id).inserted else {
            // Already restoring for an earlier click; that run finishes the attach.
            return true
        }
        worktreeRecoveryErrors.removeValue(forKey: id)
        let cwd = session.cwd
        // `displayBranch` is resolved from the cwd, so it is nil once the folder
        // is gone; it only helps for a session that went missing while running.
        let recordedBranch = session.displayBranch
        let environment = self.environment

        Task { [weak self] in
            let result = await WorktreeRecovery.recover(
                cwd: cwd,
                recordedBranch: recordedBranch,
                environment: environment
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.pendingWorktreeRecoveryIDs.remove(id)
                guard let session = self.sessions.first(where: { $0.id == id }) else { return }
                switch result {
                case .success(let recovered):
                    // Name the branch in the session's own terminal: an inferred
                    // recovery can land on a real but different branch, and this
                    // is where that becomes visible instead of silent.
                    session.feedOrQueue("\r\n\(recovered.message)\r\n")
                    if let continuation {
                        continuation(self)
                    } else {
                        try? self.respawn(id: id)
                    }
                case .failure(let failure):
                    self.worktreeRecoveryErrors[id] = failure
                }
            }
        }
        return true
    }

    func isRecoveringWorktree(id: String) -> Bool {
        pendingWorktreeRecoveryIDs.contains(id)
    }

    func worktreeRecoveryError(id: String) -> WorktreeRecovery.Failure? {
        worktreeRecoveryErrors[id]
    }

    /// Search beyond the bounded sidebar import before declaring a resume-capable
    /// history row unavailable. The scan stays off the main actor because old
    /// searchable rows may be much deeper than the recent shelf.
    ///
    /// It asks for resume candidates rather than a full import: matching needs
    /// only provider, cwd and timestamps, and a titled import of the whole
    /// corpus read gigabytes of transcript bodies to produce prompt titles this
    /// path throws away — long enough that Reopen looked like it did nothing.
    private func recoverAgentSessionIDAndRespawn(id: String) {
        guard pendingRespawnRecoveryIDs.insert(id).inserted,
              let session = sessions.first(where: { $0.id == id }) else {
            return
        }
        let cwd = session.cwd
        let createdAt = session.createdAt
        let updatedAt = session.updatedAt
        let resetAt = session.lastConversationResetAt
        let provider = session.agentProvider
        let historyBackend = historyBackend

        Task.detached(priority: .userInitiated) { [weak self] in
            let candidates = historyBackend.resumeCandidates(
                cwd: cwd,
                provider: provider,
                maxFilesScanned: Self.resumeRecoveryFileScanLimit
            )
            let match = AgentSessionMatcher.bestHistoryResumeMatch(
                sessionCWD: cwd,
                sessionCreatedAt: createdAt,
                sessionUpdatedAt: updatedAt,
                sessionResetAt: resetAt,
                provider: provider,
                in: candidates
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.pendingRespawnRecoveryIDs.remove(id)
                guard let session = self.sessions.first(where: { $0.id == id }),
                      session.status == .closed else {
                    return
                }
                guard session.agentSessionID == nil, session.lastConversationResetAt == resetAt else { return }
                if let match {
                    if !(match.provider.isOpencodeBacked && session.agentProvider?.isOpencodeBacked == true) {
                        session.markDetectedAgentProvider(match.provider)
                    }
                    session.markAgentSessionID(match.sourceID)
                    try? self.respawnAfterHistoryRecovery(id: id)
                } else {
                    self.historyResumeErrors[id] = SessionRecoveryPolicy.missingResumeMessage(provider: provider)
                }
            }
        }
    }

    func isRecoveringHistoryResume(id: String) -> Bool {
        pendingRespawnRecoveryIDs.contains(id)
    }

    func historyResumeError(id: String) -> String? {
        historyResumeErrors[id]
    }

    private func respawnAfterHistoryRecovery(id: String) throws {
        guard let session = sessions.first(where: { $0.id == id }) as? TerminalSession else {
            throw ControlError.notFound(id)
        }
        let hasLivePane: Bool
        if case .present(let pane) = tmuxBackend.agentAdmissionPane(named: session.tmuxSessionName), !pane.isDead {
            hasLivePane = true
        } else {
            hasLivePane = false
        }
        do {
            if let command = try canonicalAgentResumeCommand(for: session, allowUnresolvedIdentity: hasLivePane),
               session.command != command {
                session.command = command
            }
        } catch {
            historyResumeErrors[id] = error.localizedDescription
            throw error
        }
        session.reattachTerminalClient()
        selectedSessionID = id
        saveSessions()
    }

    nonisolated static func runBanyanWorktree(
        issueID: String,
        cwd: String,
        homeDirectory: String,
        environment: [String: String]
    ) -> String? {
        let executablePath = "\(homeDirectory)/bin/banyan-worktree"
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            return "Missing ~/bin/banyan-worktree"
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["--banyan", issueID]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        // The built-in "Start Session for <ID>" row always lands top-level.
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
            removeKeys: helperSpawnEnvironmentEdits(parentSessionID: nil).removeKeys
        )

        let stderr = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        defer { stderr.closeBothEnds() }

        do {
            try process.run()
        } catch {
            return "Unable to start banyan-worktree"
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            let message = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return message.isEmpty ? "banyan-worktree failed" : message
        }
        return nil
    }
}
