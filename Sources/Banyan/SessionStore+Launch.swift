import BanyanCore
import Foundation
import AppKit
import SwiftUI

extension SessionStore {
    /// Cmd+N: another session like the selected one — the same command in a
    /// terminal, or the same provider, model, and account in puck — beside it.
    @discardableResult
    func spawnSiblingSession() -> BanyanSession? {
        spawn(
            siblingLaunch(of: selectedSession),
            cwd: selectedSession?.cwd ?? homeDirectory,
            parentSessionID: selectedSession?.parentSessionID
        )
    }

    /// What "a session like this one" launches. With nothing selected, a
    /// plain shell.
    private func siblingLaunch(of session: BanyanSession?) -> SessionLaunchSpec {
        session?.siblingLaunch(profiles: sessionLaunchProfiles, codexLaunchMode: codexLaunchMode)
            ?? .terminal(command: NewSessionLaunch.siblingCommand(
                sessionCommand: nil,
                provider: nil,
                profiles: sessionLaunchProfiles,
                codexLaunchMode: codexLaunchMode
            ))
    }

    /// Agent entries of the launch profiles (plain shell excluded): the command
    /// palette's agent picker loops these, with Auto (nil) as the default.
    var paletteAgentProfiles: [NewSessionLaunch] {
        sessionLaunchProfiles.filter { $0.provider != nil || $0.puck != nil }
    }

    /// The palette's picked agent profile, or nil for Auto / unknown IDs.
    /// A shared accessor for palette actions: commands that have no use for
    /// an agent simply ignore it.
    var paletteAgentLaunch: NewSessionLaunch? {
        guard let id = paletteAgentProfileID else { return nil }
        return paletteAgentProfiles.first { $0.id == id }
    }

    /// Drops a persisted pick that no longer names an agent profile (e.g. the
    /// config changed since it was stored), falling back to Auto.
    func coercePaletteAgentProfile() {
        guard paletteAgentProfileID != nil, paletteAgentLaunch == nil else { return }
        paletteAgentProfileID = nil
    }

    /// Spawns the palette's picked agent as a sibling of the selected session.
    /// Falls back to copying the current session's runtime when the picker is
    /// on Auto — the same launch `spawnSiblingSession` produces.
    @discardableResult
    func spawnPaletteAgentSession() -> BanyanSession? {
        guard let launch = paletteAgentLaunch else {
            return spawnSiblingSession()
        }
        return spawn(
            launch.launchSpec(codexLaunchMode: codexLaunchMode),
            cwd: selectedSession?.cwd ?? homeDirectory,
            parentSessionID: selectedSession?.parentSessionID
        )
    }

    /// Spawns the palette's picked agent in the project root instead of the
    /// selected session's own directory. The root is the main checkout of the
    /// repository containing the selected session, so a session in a worktree or
    /// a subdirectory opens at `<repo>`; a path outside any repository stays put.
    /// The new session is top-level rather than inheriting the selected row's
    /// place in the hierarchy: opening the project root is a fresh entry point,
    /// not a sibling of whatever nested session happened to be selected.
    /// On Auto the runtime mirrors the current session, like the sibling command.
    @discardableResult
    func spawnPaletteAgentSessionInProjectRoot() -> BanyanSession? {
        let cwd = SessionDisplayLabel.workspaceRoot(
            cwd: selectedSession?.cwd ?? homeDirectory,
            environment: environment
        )
        let launch = paletteAgentLaunch?.launchSpec(codexLaunchMode: codexLaunchMode)
            ?? siblingLaunch(of: selectedSession)
        return spawn(launch, cwd: cwd, parentSessionID: nil)
    }

    /// Spawn a sibling using the selected session's coding-agent runtime when it
    /// is one of the runtimes supported by the quick new-session shortcut.
    @discardableResult
    func spawnTerminalSiblingSession() -> BanyanSession {
        let cwd = selectedSession?.cwd ?? homeDirectory
        return spawn(cwd: cwd, command: "", parentSessionID: selectedSession?.parentSessionID)
    }

    /// The kind the project header's split "+" button spawns by default —
    /// whatever was last launched for this project, defaulting to a plain shell.
    func projectLaunch(for groupID: String) -> NewSessionLaunch {
        guard let id = projectLaunchByGroup[groupID],
              let launch = sessionLaunchProfiles.first(where: { $0.id == id }) else {
            return sessionLaunchProfiles.first(where: { $0.id == "zsh" }) ?? sessionLaunchProfiles[0]
        }
        return launch
    }

    /// Finds the configured profile that launched a session so sidebar rows can
    /// retain a profile-specific label icon (for example, Luna vs. standard Codex).
    func sessionLaunchProfile(for session: BanyanSession) -> NewSessionLaunch? {
        sessionLaunchProfiles.first { session.matchesLaunchProfile($0) }
    }

    @discardableResult
    func spawnSession(inProjectGroup groupID: String, launch: NewSessionLaunch) -> BanyanSession? {
        let groupSessions = visibleSessions.filter {
            $0.projectGroupID == groupID && !$0.isImportedHistory
        }
        let preferredSessionID = SessionLaunchPolicy.preferredSessionID(
            for: selectedSessionID,
            in: groupSessions.map(\.id)
        )
        guard let preferredSessionID,
              let representative = groupSessions.first(where: { $0.id == preferredSessionID }) else {
            return nil
        }
        rememberProjectLaunch(launch, for: groupID)
        // This is a project-level control, so it opens the repository itself
        // rather than whichever worktree or subdirectory the representative
        // session happens to sit in. `spawnSiblingSession` stays session-level.
        let workspace = SessionDisplayLabel.workspaceRoot(
            cwd: representative.cwd, environment: environment
        )
        return spawn(
            launch.launchSpec(codexLaunchMode: codexLaunchMode),
            cwd: workspace,
            parentSessionID: representative.parentSessionID
        )
    }

    /// Starts a session from a launch spec. A terminal session is returned at
    /// once; a puck session appears when the daemon has created it, and a
    /// failure is reported through `puckSessionError`.
    @discardableResult
    func spawn(
        _ launch: SessionLaunchSpec,
        cwd: String?,
        parentSessionID: String?,
        id: String? = nil,
        title: String? = nil,
        tone: SessionTone = .blue,
        select: Bool = true
    ) -> BanyanSession? {
        let placementSessionID = selection.selectedSessionID
        switch launch {
        case .codex(let settings):
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.createCodexSession(settings: settings, cwd: cwd, id: id, title: title,
                        parentSessionID: parentSessionID, select: select, placementSessionID: placementSessionID)
                } catch { self.codexSessionError = error.localizedDescription }
            }
            return nil
        case .terminal(let command):
            return spawn(
                id: id,
                title: title,
                cwd: cwd,
                command: command,
                parentSessionID: parentSessionID,
                tone: tone,
                select: select,
                placementSessionID: placementSessionID
            )
        case .puck(let binding):
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.createPuckSession(
                        binding: binding,
                        cwd: cwd,
                        id: id,
                        title: title,
                        parentSessionID: parentSessionID,
                        tone: tone,
                        select: select,
                        placementSessionID: placementSessionID
                    )
                } catch {
                    self.puckSessionError = error.localizedDescription
                }
            }
            return nil
        }
    }

    private func rememberProjectLaunch(_ launch: NewSessionLaunch, for groupID: String) {
        guard projectLaunchByGroup[groupID] != launch.id else { return }
        projectLaunchByGroup[groupID] = launch.id
        UserDefaults.standard.set(
            projectLaunchByGroup,
            forKey: Self.projectLaunchDefaultsKey
        )
    }

    func showCustomSessionSheet() {
        let cwd = selectedSession?.cwd ?? homeDirectory
        addSessionDraft = .sibling(cwd: cwd)
    }

    /// Explicit native entry point, independent of the legacy remote-control/TUI preference.
    @discardableResult
    func createCodexSession(settings: CodexThreadSettings = .init(), cwd: String? = nil,
                            id proposedID: String? = nil, title: String? = nil,
                            parentSessionID: String? = nil, select: Bool = true,
                            placementSessionID: String? = nil) async throws -> CodexSession {
        let focusedSessionID = placementSessionID ?? selection.selectedSessionID
        let codexHome = try await codexThreads.preflight()
        let plan = SessionCreationPolicy.plan(proposedID: proposedID, proposedTitle: title,
            proposedTitleURL: nil, proposedCWD: cwd, proposedCommand: "",
            proposedParentSessionID: parentSessionID, currentDirectory: currentDirectory, homeDirectory: homeDirectory)
        let id = uniqueID(plan.baseID, avoidingLiveTmuxSessions: false)
        let snapshot = SessionSnapshot(id: id, tmuxSessionName: nil, title: plan.title,
            reportedTitle: nil, isTitlePinned: plan.isTitlePinned, cwd: plan.cwd, command: "",
            status: .idle, tone: .neutral, parentSessionID: plan.parentSessionID,
            createdAt: Date(), updatedAt: Date(), backend: .codex,
            codex: CodexThreadBinding(cwd: plan.cwd, settings: settings,
                codexHome: codexHome))
        let session = try CodexSession(snapshot: snapshot, coordinator: codexThreads,
            telemetry: telemetry, host: host, githubReferenceCache: githubReferenceCache)
        let previousSelection = selectedSessionID
        attach(session)
        insertCreatedSession(session, focusedSessionID: focusedSessionID)
        if select {
            expandAncestors(of: id)
            selectedSessionID = id
        }
        saveSessions()
        do {
            // Show queued creation immediately. A later selection outranks
            // this request, so completion never steals focus back.
            if select { try await codexThreads.select(sessionID: id) }
            else { try await codexThreads.connect(sessionID: id) }
        } catch {
            // Keep only rows that may own a thread. Definite pre-start failures
            // must not leave a half-created row behind.
            if !(error is CancellationError), codexThreads.states[id]?.binding.creationAttempted == false {
                sessions.removeAll { $0.id == id }
                codexThreads.discardUnstartedSession(sessionID: id)
                if selectedSessionID == id { selectedSessionID = previousSelection }
                saveSessions()
                await codexThreads.flushPersistence?()
                // Restore the actual UI selection after removing a failed
                // creation; never leave native selection pointing at no row.
                if select { try? await codexThreads.select(sessionID: (selectedSession as? CodexSession)?.id) }
            }
            throw error
        }
        return session
    }

    /// Replace the runtime, not the row identity. Persist before any terminal
    /// launch so a crash/restart still resumes the original thread and settings.
    @discardableResult
    func fallbackCodexSessionToCLI(id: String) async throws -> TerminalSession {
        guard let native = sessions.first(where: { $0.id == id }) as? CodexSession else {
            throw ControlError.notFound(id)
        }
        native.codexAutoRetry.cancel()
        let reason = native.state.connection.message ?? "User selected Codex CLI"
        var binding = try await codexThreads.prepareForCLIFallback(sessionID: id)
        guard let index = sessions.firstIndex(where: { $0 === native }) else {
            throw ControlError.notFound(id)
        }
        binding.cliFallbackReason = reason
        let snapshot = native.persistenceSnapshot
        let terminal = TerminalSession(id: id,
            title: snapshot.title, titleURL: snapshot.titleURL,
            titleURLWasAutoDetected: snapshot.titleURLWasAutoDetected,
            generatedTitle: snapshot.generatedTitle, isTitlePinned: snapshot.isTitlePinned,
            cwd: binding.cwd, command: try CodexCLIFallback.command(binding: binding),
            status: snapshot.status == .closed ? .closed : .idle, tone: snapshot.tone,
            parentSessionID: snapshot.parentSessionID, agentSessionID: binding.threadID,
            createdAt: snapshot.createdAt, updatedAt: Date(), isSuspended: snapshot.isSuspended,
            theme: terminalTheme, fontFamily: terminalFontFamily, fontSize: terminalFontSize,
            tmuxBackend: sessionBackend, telemetry: telemetry, host: host,
            githubReferenceCache: githubReferenceCache)
        terminal.nativeCodexProvenance = binding
        terminal.reportedTitle = snapshot.reportedTitle
        terminal.contextualTitle = snapshot.contextualTitle
        attach(terminal)
        sessions[index] = terminal
        saveSessions()
        await codexThreads.flushPersistence?()
        if terminal.status != .closed && !terminal.isSuspended { terminal.startBackgroundBackendIfNeeded() }
        requestTerminalFocus()
        return terminal
    }

    func showChildSessionSheet() {
        guard let selectedSession else { return }
        addSessionDraft = .child(of: selectedSession)
    }

    @discardableResult
    func spawn(
        id proposedID: String? = nil,
        title proposedTitle: String? = nil,
        titleURL proposedTitleURL: String? = nil,
        cwd proposedCWD: String? = nil,
        command proposedCommand: String? = nil,
        parentSessionID proposedParentSessionID: String? = nil,
        tone: SessionTone = .blue,
        select: Bool = true,
        placementSessionID: String? = nil
    ) -> TerminalSession {
        let command: String?
        if enableCodexAppServerMode, let proposedCommand {
            command = CodexAppServerLaunch.upgradedDirectCommand(proposedCommand) ?? proposedCommand
        } else {
            command = proposedCommand
        }
        let plan = SessionCreationPolicy.plan(
            proposedID: proposedID,
            proposedTitle: proposedTitle,
            proposedTitleURL: proposedTitleURL,
            proposedCWD: proposedCWD,
            proposedCommand: command,
            proposedParentSessionID: proposedParentSessionID,
            currentDirectory: currentDirectory,
            homeDirectory: homeDirectory
        )
        let id = uniqueID(plan.baseID, avoidingLiveTmuxSessions: true)
        let session = TerminalSession(
            id: id,
            tmuxSessionName: SessionIdentityPolicy.sessionName(for: id),
            title: plan.title,
            titleURL: plan.titleURL,
            generatedTitle: nil,
            isTitlePinned: plan.isTitlePinned,
            cwd: plan.cwd,
            command: plan.command,
            tone: tone,
            parentSessionID: plan.parentSessionID,
            agentSessionID: proposedCommand.flatMap { AgentSessionHistory.explicitResumeIdentity(in: $0)?.sourceID },
            theme: terminalTheme,
            fontFamily: terminalFontFamily,
            fontSize: terminalFontSize,
            tmuxBackend: sessionBackend,
            telemetry: telemetry,
            host: host,
            githubReferenceCache: githubReferenceCache
        )
        attach(session)
        insertCreatedSession(session, focusedSessionID: placementSessionID ?? selection.selectedSessionID)
        if select {
            expandAncestors(of: session.id)
            selectedSessionID = session.id
            refreshSelectedContextInfo(force: true)
            session.startBackgroundBackendIfNeeded()
        } else {
            // Keep the user's current selection/focus; still run the command so
            // background spawns (e.g. `agent run`) actually start.
            session.startBackgroundBackendIfNeeded()
        }
        saveSessions()
        return session
    }

    func insertCreatedSession(_ session: BanyanSession, focusedSessionID: String?) {
        let candidates = visibleSessions.filter { !$0.isImportedHistory }.map {
            SessionSidebarCandidate(id: $0.id, groupID: $0.projectGroupID,
                groupTitle: $0.projectGroupTitle, parentSessionID: $0.parentSessionID)
        }
        let nextID = SessionSidebarCreationPolicy.insertionBeforeID(
            in: candidates, groupID: session.projectGroupID,
            parentSessionID: session.parentSessionID, focusedSessionID: focusedSessionID,
            sortMode: sortMode
        )
        let index = nextID.flatMap { nextID in sessions.firstIndex { $0.id == nextID } } ?? sessions.endIndex
        sessions.insert(session, at: index)
    }

    func uniqueID(_ baseID: String, avoidingLiveTmuxSessions: Bool) -> String {
        SessionIdentityPolicy.nextAvailableID(from: baseID) { candidate in
            isAvailableID(candidate, avoidingLiveTmuxSessions: avoidingLiveTmuxSessions)
        }
    }

    private func isAvailableID(_ id: String, avoidingLiveTmuxSessions: Bool) -> Bool {
        // Removed/closing rows can still own live or uncertain work. Reusing
        // their ID would alias two runtimes onto one resource reservation.
        guard !agentAdmission.running.contains(id), agentAdmission.position(of: id) == nil else { return false }
        guard !codexThreads.reserves(sessionID: id) else { return false }
        guard !sessions.contains(where: { $0.id == id }) else {
            return false
        }
        if avoidingLiveTmuxSessions, tmuxBackend.hasSession(named: SessionIdentityPolicy.sessionName(for: id)) {
            return false
        }
        return true
    }
}
