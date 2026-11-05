import BanyanCore
import Foundation
import AppKit
import SwiftUI

extension SessionStore {
    func installCodexTitleWatcherIfNeeded() {
        guard codexTitleWatcher == nil else { return }
        lastCodexGeneratedTitles = CodexSessionTitleIndex.generatedTitles(homeDirectory: host.homeDirectory)
        let watcher = CodexSessionIndexWatcher(
            url: CodexSessionTitleIndex.indexURL(homeDirectory: host.homeDirectory)
        ) { [weak self] in
            self?.refreshCodexTitlesFromIndex()
        }
        watcher.start()
        codexTitleWatcher = watcher
    }

    /// A generated Codex title is a small index-file update. Apply it to the
    /// sessions we already know instead of rescanning every provider transcript.
    /// A new Banyan session without a Codex thread ID still needs one import to
    /// establish that identity; unchanged transcripts come from the cache.
    func refreshCodexTitlesFromIndex() {
        let titles = CodexSessionTitleIndex.generatedTitles(homeDirectory: host.homeDirectory)
        let changed = titles.filter { lastCodexGeneratedTitles[$0.key] != $0.value }
        lastCodexGeneratedTitles = titles
        // The import cannot hang off a rename. A thread only appears here once
        // Codex records a name for it, and many sessions — a profile running a
        // model on a custom gateway, say — never get one at all, so its row
        // never arrives to trigger the scan. A live codex session without a
        // transcript stays the honest reason to rescan, whatever changed.
        if sessions.contains(where: {
            $0.matchesAgentTranscripts
                && $0.status != .closed && $0.agentProvider == .codex && $0.agentSessionID == nil
        }) {
            runHistoryImport()
        }
        guard !changed.isEmpty else { return }

        var updatedHistory = false
        latestImportedHistory = latestImportedHistory.map { imported in
            guard imported.provider == .codex,
                  !imported.segmentWasCleared,
                  let title = changed[imported.sourceID] else {
                return imported
            }
            updatedHistory = true
            return ImportedAgentSession(
                id: imported.id,
                provider: imported.provider,
                sourceID: imported.sourceID,
                title: title,
                segmentPromptTitle: imported.segmentPromptTitle,
                segmentWasCleared: imported.segmentWasCleared,
                agentGeneratedTitle: title,
                cwd: imported.cwd,
                transcriptURL: imported.transcriptURL,
                createdAt: imported.createdAt,
                updatedAt: imported.updatedAt
            )
        }
        if updatedHistory {
            refreshLiveAgentTitles(from: latestImportedHistory)
        }
        for session in sessions where session.matchesAgentTranscripts
            && session.status != .closed && session.agentProvider == .codex {
            guard session.lastConversationResetAt == nil,
                  let sourceID = session.agentSessionID,
                  let title = changed[sourceID] else { continue }
            session.markAgentGeneratedTitle(title)
        }
    }

    /// A live agent row whose transcript Banyan has not located yet. Both its
    /// title and its resume id come from a provider-history import, so an import
    /// is worth its cost exactly while one of these exists.
    private var hasUnmatchedLiveAgentSession: Bool {
        sessions.contains { session in
            session.matchesAgentTranscripts
                && !session.isImportedHistory
                && session.status != .closed
                && session.agentProvider != nil
                && session.agentSessionID == nil
        }
    }

    /// The launch import used to rescan every provider transcript on the chance
    /// a sidebar row needed one. Do that only when it does: a restored, already
    /// matched sidebar needs no history read unless its title captured only the
    /// image marker before the remaining transcript parts were considered.
    func refreshImportedHistoryIfNeeded() {
        let hasImageOnlyTitle = sessions.contains {
            $0.matchesAgentTranscripts
                && !$0.isImportedHistory
                && $0.status != .closed
                && $0.agentProvider != nil
                && !$0.isTitlePinned
                && ["<img>", "<image>"].contains($0.displayTitle)
        }
        guard hasUnmatchedLiveAgentSession || hasImageOnlyTitle else { return }
        runHistoryImport()
    }

    /// A turn that just started is the moment the agent's transcript gains the
    /// prompt Banyan titles the session from. Agents that name their own threads
    /// announce that in the Codex session index, but a session the agent never
    /// names — a profile running a model on a custom gateway, for instance —
    /// never touches that file, leaving the transcript as the only source and
    /// the index watcher silent. Read it once, a beat after the turn begins,
    /// instead of polling for it.
    func scheduleAgentTitleImportIfNeeded(for session: BanyanSession) {
        guard session.matchesAgentTranscripts,
              !session.isImportedHistory,
              session.status != .closed,
              session.agentProvider != nil,
              session.agentSessionID == nil,
              session.reportedTitle == nil else {
            return
        }
        guard session.agentTitleImportAttempts < Self.agentTitleImportAttemptLimit else { return }
        session.agentTitleImportAttempts += 1
        guard agentTitleImportTask == nil else { return }
        agentTitleImportTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.agentTitleImportDelay)
            guard let self, !Task.isCancelled else { return }
            self.agentTitleImportTask = nil
            guard self.hasUnmatchedLiveAgentSession else { return }
            self.runHistoryImport()
        }
    }

    func refreshImportedHistory(spawnDefaultIfEmpty: Bool = false) {
        runHistoryImport(spawnDefaultIfEmpty: spawnDefaultIfEmpty)
    }

    /// Restore the normal first-launch behavior without importing every agent
    /// transcript merely because the main window appeared. Persisted sessions
    /// already carry their titles and provider IDs; provider imports are still
    /// available to workflows that actually need new transcript metadata.
    func spawnDefaultSessionIfEmpty() {
        guard !sessions.contains(where: { $0.status != .closed }) else { return }
        spawn(cwd: homeDirectory)
    }

    func transcriptPreview(
        from url: URL,
        provider: CodingAgentProvider,
        maxMessages: Int = 40
    ) async -> String {
        let historyBackend = historyBackend
        return await Task.detached(priority: .utility) {
            historyBackend.transcriptPreview(
                from: url,
                provider: provider,
                maxMessages: maxMessages
            )
        }.value
    }

    /// Resolve the transcript for a row from identities Banyan already knows.
    /// Imported history is preferred when present; otherwise the backend looks
    /// up the exact provider transcript without importing unrelated sessions.
    func sessionCostTranscriptSource(for session: BanyanSession) -> SessionCostTranscriptSource? {
        if let source = SessionCostTranscriptResolver.importedHistorySource(
            provider: session.agentProvider,
            transcriptURL: session.historyTranscriptURL
        ) {
            return source
        }
        if let source = SessionCostTranscriptResolver.source(
            provider: session.agentProvider,
            agentSessionID: session.agentSessionID,
            importedHistory: latestImportedHistory
        ) {
            return source
        }

        guard let provider = session.agentProvider,
              [.codex, .claude].contains(provider),
              let sourceID = session.agentSessionID,
              !sourceID.isEmpty else {
            return nil
        }
        let cacheKey = "\(provider.rawValue):\(sourceID)"
        if let cached = sessionCostTranscriptSources[cacheKey] {
            return cached
        }
        guard let transcriptURL = historyBackend.transcriptURL(
            provider: provider,
            sourceID: sourceID,
            cwd: session.cwd,
            createdAt: session.createdAt
        ) else {
            return nil
        }
        let source = SessionCostTranscriptSource(
            provider: provider == .codex ? .codex : .claude,
            transcriptURL: transcriptURL,
            sessionKey: cacheKey
        )
        sessionCostTranscriptSources[cacheKey] = source
        return source
    }

    func sessionCostEstimate(for source: SessionCostTranscriptSource) async -> SessionCostEstimate? {
        let cache = sessionCostCache
        return await Task.detached(priority: .utility) {
            guard let transcript = cache.transcript(
                at: source.transcriptURL,
                provider: source.provider
            ) else {
                return SessionCostEstimate.unavailable(.unreadableTranscript)
            }
            return SessionCostCalculator.estimate(transcript: transcript)
        }.value
    }

    @discardableResult
    func resumeImportedHistory(id: String, prompt: String? = nil) throws -> BanyanSession {
        guard let history = sessions.first(where: { $0.id == id && $0.isImportedHistory }) else {
            throw ControlError.notFound(id)
        }
        guard let provider = history.agentProvider,
              let sourceID = historyBackend.sourceID(fromImportedSessionID: history.id, provider: provider),
              let plan = SessionResumePolicy.plan(
                provider: provider,
                sourceID: sourceID,
                cwd: history.cwd,
                prompt: prompt,
                transcriptURL: history.historyTranscriptURL,
                trimmed: false,
                history: historyBackend
              ) else {
            throw ControlError.badRequest("Session history item '\(id)' cannot be resumed")
        }
        return spawn(
            id: SessionResumePolicy.sessionIDPrefix(provider: provider, sourceID: plan.sourceID),
            title: history.displayTitle,
            cwd: history.cwd,
            command: preferredResumeCommand(
                provider: provider,
                sourceID: plan.sourceID,
                cwd: history.cwd,
                prompt: prompt,
                directCommand: plan.command,
                previousCommand: history.command
            ),
            tone: .blue
        )
    }

    /// Resume an imported history item from a trimmed copy of its transcript so
    /// the first (and every) follow-up turn replays fewer input tokens. Falls back
    /// to `resumeImportedHistory` when there's nothing worth trimming or the
    /// transcript can't be prepared. The original transcript is never modified.
    func resumeImportedHistoryTrimmed(id: String, prompt: String? = nil) {
        guard let history = sessions.first(where: { $0.id == id && $0.isImportedHistory }),
              let provider = history.agentProvider,
              let sourceID = historyBackend.sourceID(fromImportedSessionID: history.id, provider: provider) else {
            _ = try? resumeImportedHistory(id: id, prompt: prompt)
            return
        }
        let cwd = history.cwd
        let title = history.displayTitle
        let transcriptURL = history.historyTranscriptURL
        let previousCommand = history.command
        let historyBackend = historyBackend
        Task.detached(priority: .userInitiated) {
            let plan = SessionResumePolicy.plan(
                provider: provider,
                sourceID: sourceID,
                cwd: cwd,
                prompt: prompt,
                transcriptURL: transcriptURL,
                trimmed: true,
                history: historyBackend
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard let plan else {
                    _ = try? self.resumeImportedHistory(id: id, prompt: prompt)
                    return
                }
                self.spawn(
                    id: SessionResumePolicy.sessionIDPrefix(
                        provider: provider,
                        sourceID: plan.sourceID
                    ),
                    title: title,
                    cwd: cwd,
                    command: self.preferredResumeCommand(
                        provider: provider,
                        sourceID: plan.sourceID,
                        cwd: cwd,
                        prompt: prompt,
                        directCommand: plan.command,
                        previousCommand: previousCommand
                    ),
                    tone: .blue
                )
            }
        }
    }

    var codexLaunchMode: CodexLaunchMode {
        enableCodexAppServerMode ? .appServer : .direct
    }

    func prepareAgentResumeForRestart(_ session: TerminalSession) throws {
        guard let command = try canonicalAgentResumeCommand(for: session), session.command != command else { return }
        session.command = command
    }

    func canonicalAgentResumeCommand(
        for session: TerminalSession,
        allowUnresolvedIdentity: Bool = false
    ) throws -> String? {
        if let binding = session.codexBinding {
            return try CodexCLIFallback.command(binding: binding)
        }
        let agentSessionID = session.agentSessionID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let provider = session.agentProvider else {
            if !agentSessionID.isEmpty, !allowUnresolvedIdentity {
                throw ControlError.badRequest(
                    "This session has a saved conversation ID but its provider is unresolved. The original command was not restarted."
                )
            }
            return nil
        }
        guard [.codex, .claude].contains(provider) || provider.isOpencodeBacked else {
            if !agentSessionID.isEmpty, !allowUnresolvedIdentity {
                throw ControlError.badRequest(
                    "\(provider.displayName) sessions cannot be resumed safely. The original command was not restarted."
                )
            }
            return nil
        }
        guard !agentSessionID.isEmpty else {
            if allowUnresolvedIdentity { return nil }
            throw ControlError.badRequest(
                "\(provider.displayName) has no resolved conversation ID. The original command was not restarted."
            )
        }
        guard let resumePlan = SessionRecoveryPolicy.resumePlan(
            status: session.status,
            provider: provider,
            agentSessionID: agentSessionID,
            cwd: session.cwd,
            history: historyBackend
        ) else {
            throw ControlError.badRequest(SessionRecoveryPolicy.missingResumeMessage(provider: provider))
        }
        do {
            return try canonicalResumeCommand(
                provider: provider,
                sourceID: resumePlan.sourceID,
                cwd: session.cwd,
                directCommand: resumePlan.command,
                previousCommand: session.command
            )
        } catch {
            throw ControlError.badRequest(error.localizedDescription)
        }
    }

    func canonicalResumeCommand(
        provider: CodingAgentProvider,
        sourceID: String,
        cwd: String,
        directCommand: String,
        previousCommand: String
    ) throws -> String {
        if provider == .codex, CodexAppServerLaunch.isAppServerCommand(previousCommand) || enableCodexAppServerMode {
            let launchCommand = CodexAppServerLaunch.directLaunchCommand(from: previousCommand) ?? previousCommand
            let direct = try AgentResumeCommand.plan(
                provider: provider,
                sourceID: sourceID,
                cwd: cwd,
                launchCommand: launchCommand,
                baseResumeCommand: directCommand
            )
            guard let command = CodexAppServerLaunch.wrappingRemoteTUI(direct.command) else {
                throw AgentFreezeError.unsafe("Codex app-server launch options cannot be safely preserved; the original command was not restarted.")
            }
            return command
        }
        return try AgentResumeCommand.plan(
            provider: provider,
            sourceID: sourceID,
            cwd: cwd,
            launchCommand: previousCommand,
            baseResumeCommand: directCommand
        ).command
    }

    private func preferredResumeCommand(
        provider: CodingAgentProvider?,
        sourceID: String,
        cwd: String,
        prompt: String?,
        directCommand: String,
        previousCommand: String? = nil
    ) -> String {
        let command: String
        if provider == .codex,
           enableCodexAppServerMode || previousCommand.map(CodexAppServerLaunch.isAppServerCommand) == true {
            command = CodexAppServerLaunch.resumeCommand(sourceID: sourceID, cwd: cwd, prompt: prompt)
        } else {
            command = directCommand
        }
        // Codex replays the provider recorded in the transcript, so a resume that
        // lost the `-p <profile>` its session launched with dies at startup with
        // "Model provider … not found" and takes the recovered session with it.
        return AgentSessionHistory.applyingCodexProfile(fromCommand: previousCommand, to: command)
    }

    func runHistoryImport(spawnDefaultIfEmpty: Bool = false) {
        guard !isHistoryImportRunning else {
            isHistoryImportPending = true
            return
        }
        isHistoryImportRunning = true
        let historyBackend = historyBackend
        let telemetry = telemetry
        Task.detached(priority: .utility) {
            let startedAt = DispatchTime.now()
            let imported = historyBackend.load(maxPerProvider: SessionHistoryPresentation.recoveryImportLimit)
            telemetry.recordDurationLocalIfSlow(
                "history.import",
                durationMS: PerformanceTelemetry.elapsedMS(since: startedAt),
                detail: "sessions=\(imported.count)"
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.applyImportedHistory(imported)
                self.isHistoryImportRunning = false
                let shouldRunPendingImport = self.isHistoryImportPending
                self.isHistoryImportPending = false
                if spawnDefaultIfEmpty, !self.sessions.contains(where: { $0.status != .closed }) {
                    self.spawn(cwd: homeDirectory)
                }
                if shouldRunPendingImport {
                    self.runHistoryImport()
                }
            }
        }
    }

    private func applyImportedHistory(_ imported: [ImportedAgentSession]) {
        latestImportedHistory = imported
        if sessions.contains(where: \.isImportedHistory) {
            sessions.removeAll { $0.isImportedHistory }
        }
        refreshLiveAgentTitles(from: imported)

        if let selectedSessionID, !sidebarSessions.contains(where: { $0.id == selectedSessionID }) {
            self.selectedSessionID = sidebarSessions.first?.id
        } else if selectedSessionID == nil {
            selectedSessionID = sidebarSessions.first?.id
        }
    }

    func refreshLiveAgentTitles(from imported: [ImportedAgentSession]) {
        let candidates = imported.filter {
            [.claude, .codex].contains($0.provider) || $0.provider.isOpencodeBacked
        }
        guard !candidates.isEmpty else { return }

        let liveSessions = sessions.filter {
            $0.matchesAgentTranscripts && AgentSessionMatcher.participatesInLiveAgentMatch(
                isImportedHistory: $0.isImportedHistory,
                status: $0.status,
                provider: $0.agentProvider
            )
        }
        let inputs = liveSessions.map {
            AgentSessionMatchInput(
                id: $0.id,
                cwd: $0.cwd,
                createdAt: $0.createdAt,
                resetAt: $0.lastConversationResetAt,
                provider: $0.agentProvider,
                sourceID: $0.agentSessionID
            )
        }
        let matchesBySessionID = AgentSessionMatcher.bestPromptTitleAssignments(
            for: inputs,
            in: candidates
        )

        for session in liveSessions {
            guard let match = matchesBySessionID[session.id] else { continue }
            // Opencode candidates are always generic `.opencode` (one shared
            // SQLite store); a live session may already carry a refined
            // opencode-backed identity (`.muse`, `.deepseek`, …) from the model
            // database. Never downgrade that — only capture the session ID.
            if match.provider.isOpencodeBacked,
               session.agentProvider?.isOpencodeBacked == true {
                session.markAgentSessionID(match.sourceID)
                continue
            }
            if session.detectedAgentProvider != match.provider {
                session.markDetectedAgentProvider(match.provider)
            }
            session.markAgentSessionID(match.sourceID)
            // The agent's own name for the conversation wins when it has one.
            // A reset makes it stale — it still describes the pre-/clear
            // conversation — so fall back to the segment title after a clear.
            if let agentTitle = match.agentGeneratedTitle,
               session.lastConversationResetAt == nil {
                session.markAgentGeneratedTitle(agentTitle)
                continue
            }
            // Use the current-segment title so a freshly cleared conversation
            // (segment title nil until the next prompt) does not get its
            // pre-/clear first-prompt title resurrected onto the live session.
            if let segmentTitle = match.segmentPromptTitle {
                session.markFirstPromptTitle(segmentTitle)
            } else if match.segmentWasCleared {
                // The transcript shows a /clear or /new with no prompt since.
                // Actively drop the stale title even when the keystroke path
                // missed the reset (autocomplete, paste, unfocused terminal,
                // or a /clear issued while Banyan was closed).
                session.noteConversationResetFromTranscript()
            }
        }
    }
}
