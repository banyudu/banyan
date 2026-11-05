import BanyanCore
import Foundation
import AppKit
import SwiftUI

extension SessionStore {
    /// Performance events are buffered in memory and written in batches, so quitting
    /// has to drain them or the last few seconds of telemetry are lost.
    nonisolated func flushPendingTelemetry() {
        telemetry.flushPendingEventsAndWait(endingActiveSpans: true)
        telemetry.axiomExporter?.shutdownBlocking()
    }

    /// Blocks until the serial session-persistence queue drains. Safe to call from a
    /// non-isolated context (only touches the immutable, Sendable queue).
    nonisolated func flushPendingSessionSaves() {
        sessionPersistenceQueue.sync {}
    }

    func loadPersistedSessionsIfNeeded() {
        guard !didLoadPersistedSessions else { return }
        didLoadPersistedSessions = true
        // Before `load()`, not after: every aged-out row dropped here is a row
        // whose `cwd` the loop below would otherwise resolve git context for,
        // and that resolution is what a cold start spends its time on.
        persistence.pruneExpiredSessions(retentionDays: sessionRetentionDays)
        let snapshots = persistence.load()
        let liveTmuxSessionNames = Set(tmuxBackend.listBanyanSessions())
        var loadedTmuxSessionNames = Set<String>()
        // Hundreds of historical rows often share a cwd. Repository context is a
        // property of that directory, not of an individual session, so resolve it
        // once during this restore pass instead of spawning the same local git
        // commands for every row.
        var displayContextsByCWD: [String: SessionProjectContext] = [:]
        for snapshot in snapshots {
            let restorationPlan = SessionRestorationPolicy.plan(
                for: snapshot,
                liveTmuxSessionNames: liveTmuxSessionNames
            )
            let displayContext: SessionProjectContext
            if snapshot.status == .closed {
                displayContext = SessionDisplayLabel.historicalContext(
                    cwd: snapshot.cwd,
                    homeDirectory: homeDirectory
                )
            } else if let cached = displayContextsByCWD[snapshot.cwd] {
                displayContext = cached
            } else {
                let resolved = SessionDisplayLabel.cachedContext(
                    cwd: snapshot.cwd,
                    homeDirectory: homeDirectory,
                    environment: environment
                )
                displayContextsByCWD[snapshot.cwd] = resolved
                displayContext = resolved
            }
            if snapshot.backend == .codex {
                do {
                    let session = try CodexSession(snapshot: snapshot, coordinator: codexThreads,
                        displayContext: displayContext, telemetry: telemetry, host: host,
                        githubReferenceCache: githubReferenceCache)
                    attach(session)
                    sessions.append(session)
                    if snapshot.agentSlotReserved || [.executing, .asking, .failed].contains(snapshot.status) {
                        codexThreads.adoptRestoredWork(sessionID: snapshot.id)
                    }
                    if enableNativeCodex && agentAdmission.running.contains(snapshot.id) {
                        session.reconnect()
                    }
                } catch { codexSessionError = error.localizedDescription }
                continue
            }
            if snapshot.backend == .puck {
                // A puck row without its runtime cannot be followed, and must
                // not come back as a shell either.
                guard let binding = snapshot.puck else { continue }
                if snapshot.agentSlotReserved { agentAdmission.adopt(snapshot.id) }
                // Status comes back from the daemon on the first listing; until
                // then the row shows what it last showed.
                let session = PuckSession(
                    id: snapshot.id,
                    binding: binding,
                    title: SessionRestorationPolicy.restoredTitle(
                        for: snapshot,
                        homeDirectory: homeDirectory
                    ),
                    titleURL: snapshot.titleURL,
                    titleURLWasAutoDetected: snapshot.titleURLWasAutoDetected,
                    reportedTitle: snapshot.reportedTitle,
                    generatedTitle: snapshot.generatedTitle,
                    isTitlePinned: snapshot.isTitlePinned,
                    cwd: snapshot.cwd,
                    status: snapshot.status,
                    tone: snapshot.tone,
                    parentSessionID: snapshot.parentSessionID,
                    createdAt: snapshot.createdAt,
                    updatedAt: snapshot.updatedAt,
                    isSuspended: snapshot.isSuspended,
                    displayContext: displayContext,
                    daemon: puckDaemon,
                    telemetry: telemetry,
                    host: host,
                    githubReferenceCache: githubReferenceCache
                )
                session.contextualTitle = snapshot.contextualTitle
                attach(session)
                sessions.append(session)
                continue
            }
            let session = TerminalSession(
                id: uniqueID(snapshot.id, avoidingLiveTmuxSessions: false),
                tmuxSessionName: restorationPlan.tmuxSessionName,
                title: SessionRestorationPolicy.restoredTitle(
                    for: snapshot,
                    homeDirectory: homeDirectory
                ),
                titleURL: snapshot.titleURL,
                titleURLWasAutoDetected: snapshot.titleURLWasAutoDetected,
                generatedTitle: snapshot.generatedTitle,
                isTitlePinned: snapshot.isTitlePinned,
                cwd: snapshot.cwd,
                command: snapshot.command,
                status: restorationPlan.status,
                tone: snapshot.tone,
                parentSessionID: snapshot.parentSessionID,
                agentSessionID: snapshot.agentSessionID,
                createdAt: snapshot.createdAt,
                updatedAt: snapshot.updatedAt,
                isRestored: true,
                needsRecovery: restorationPlan.needsRecovery,
                isSuspended: snapshot.isSuspended,
                displayContext: displayContext,
                theme: terminalTheme,
                fontFamily: terminalFontFamily,
                fontSize: terminalFontSize,
                tmuxBackend: sessionBackend,
                telemetry: telemetry,
                host: host,
                githubReferenceCache: githubReferenceCache
            )
            session.reportedTitle = snapshot.reportedTitle
            session.contextualTitle = snapshot.contextualTitle
            session.nativeCodexProvenance = snapshot.codex
            session.agentLaunchQueue = snapshot.agentLaunchQueue
            session.admissionProviderIdentity = snapshot.agentSlotProviderIdentity
            session.admissionProcessIdentity = snapshot.agentSlotPaneIdentity
            session.admissionPanePID = snapshot.agentSlotPaneIdentity?.pid
            // An idle command does not need a reservation to sit at its prompt,
            // and queueing one would only delay new work until something else
            // exited. Its reservation is re-adopted when it is seen working.
            if !snapshot.status.isCodingAgentIdle,
               snapshot.agentSlotReserved || (liveTmuxSessionNames.contains(session.tmuxSessionName) && session.status != .closed &&
               !session.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
               snapshot.agentSlotProviderIdentity.map({ AgentProcessSample.presence(of: $0) != .exited }) != false) {
                agentAdmission.adopt(session.id)
                session.admissionLaunchSucceeded = true
                session.agentLaunchQueue = nil
            }
            attach(session)
            sessions.append(session)
            if session.status != .closed {
                loadedTmuxSessionNames.insert(session.tmuxSessionName)
            }
        }
        restoreWorkflows()
        restoreBackgroundPresentation()
        // Background roots remain discoverable in the familiar session tree.
        foldedParentIDs.formUnion(backgroundSessionRoots)
        // Register the whole restored fleet before any recovery can claim a
        // new slot. Over-budget work stays intact, including parked/frozen rows.
        for terminal in terminalSessions where agentAdmission.running.contains(terminal.id) {
            reconcileAgentAdmission(id: terminal.id)
        }
        for terminal in terminalSessions.sorted(by: {
            ($0.agentLaunchQueue?.requestedAt ?? .distantFuture) < ($1.agentLaunchQueue?.requestedAt ?? .distantFuture)
        }) where terminal.agentLaunchQueue?.cancelled == false {
            terminal.needsRecovery = false
            // This persisted queue is an explicit pending launch, rather than
            // an attachment to a previously running conversation.
            terminal.isRestored = false
            retryQueuedAgent(id: terminal.id)
        }
        for tmuxSessionName in SessionHistoryPresentation.staleTmuxSessionNames(
            liveSessionNames: tmuxBackend.listBanyanSessions(),
            persistedSessionNames: loadedTmuxSessionNames
        ) {
            tmuxBackend.killSession(named: tmuxSessionName)
        }
        if let selectedSessionID, visibleSessions.contains(where: { $0.id == selectedSessionID }) {
            self.selectedSessionID = selectedSessionID
        } else {
            selectedSessionID = visibleSessions.first?.id
        }
        // Keep startup non-modal. Recovery may need a macOS security-scoped
        // folder grant, and presenting NSOpenPanel while SwiftUI is restoring
        // its window can deadlock or crash the system renderer. The recovery
        // banner calls recoverAll after the main window and control server are
        // ready, so one parent-folder grant can be reused for all sessions.
        refreshSelectedContextInfo(force: true)
        saveSessions()
        retryDegradedDisplayContexts()
    }

    /// The closed sessions a retention window would drop right now.
    ///
    /// Imported history rows can never be candidates — they are rebuilt from the
    /// agent's own transcripts rather than from `state.sqlite`, exactly as
    /// `saveSessions` treats them — but they still take part as parents, so a
    /// persisted row one of them hangs off stays. Neither can a closed session
    /// that still names an agent thread: that row is how the conversation is
    /// resumed, so it is not the prune's to delete.
    func expiredSessionIDs(retentionDays: Int) -> [String] {
        let importedHistoryIDs = Set(sessions.filter(\.isImportedHistory).map(\.id))
        return SessionRetentionPolicy.expiredSessionIDs(
            rows: sessions.map {
                SessionRetentionPolicy.Row(
                    id: $0.id,
                    parentSessionID: $0.parentSessionID,
                    status: $0.status,
                    updatedAt: $0.updatedAt,
                    agentSessionID: $0.agentSessionID,
                    backingOutlivesClose: $0.backendKind != .terminal
                )
            },
            cutoff: SessionRetentionPolicy.cutoff(retentionDays: retentionDays),
            selectedSessionID: selectedSessionID
        )
        .filter { !importedHistoryIDs.contains($0) }
    }

    var expiredSessionCount: Int {
        expiredSessionIDs(retentionDays: sessionRetentionDays).count
    }

    /// Drops aged-out closed sessions from the sidebar, which `saveSessions`
    /// then writes through to `state.sqlite`. Returns how many went.
    ///
    /// Nothing is signalled or killed. A closed session's tmux backing is
    /// already reaped at every launch — `staleTmuxSessionNames` only spares the
    /// names of rows that came back non-closed — so there is nothing left here
    /// for a prune to tear down, and a row that somehow still has one is better
    /// left alone than killed behind the user's back.
    @discardableResult
    func pruneExpiredSessions(retentionDays: Int) -> Int {
        let expired = Set(expiredSessionIDs(retentionDays: retentionDays))
        guard !expired.isEmpty else { return 0 }
        sessions.removeAll { expired.contains($0.id) }
        saveSessions()
        // Same follow-up `remove` does: a pruned row may have been shadowing an
        // agent transcript that now belongs back in the History list.
        refreshImportedHistory()
        return expired.count
    }

    /// Encoding and writing the Linear list cache is a multi-megabyte SQLite
    /// write. It shares the serial persistence queue with session saves so it
    /// can neither block the main actor nor overtake a pending session write.
    func persistLinearIssueListCache(_ snapshot: LinearIssueListCacheSnapshot) {
        let persistence = persistence
        sessionPersistenceQueue.async {
            persistence.saveLinearIssueListCache(snapshot)
        }
    }

    func saveSessions() {
        let snapshots = sessions.filter { !$0.isImportedHistory }.map(\.persistenceSnapshot)
        // Supervisor ticks call this every cycle; skip the SQLite rewrite entirely
        // when nothing changed. This was the dominant main-thread stall behind the
        // "Application Not Responding" freezes.
        guard snapshots != lastSavedSessionSnapshots else { return }
        lastSavedSessionSnapshots = snapshots
        lastSavedSnapshotIndexByID = Dictionary(
            uniqueKeysWithValues: snapshots.enumerated().map { ($0.element.id, $0.offset) }
        )
        let persistence = persistence
        // Perform the actual open+migrate+DELETE+re-insert off the main thread so a
        // real change never blocks the UI; the serial queue preserves write order.
        sessionPersistenceQueue.async {
            persistence.save(snapshots)
        }
    }

    func saveChangedSession(_ session: BanyanSession) {
        let trace = EnergyTrace.span("store.saveSession", sessionID: session.id)
        defer { trace?.end() }
        guard !session.isImportedHistory else { return }
        guard let index = lastSavedSnapshotIndexByID[session.id],
              lastSavedSessionSnapshots?.indices.contains(index) == true,
              lastSavedSessionSnapshots?[index].id == session.id else {
            // The first save and any structural change still need the full set.
            saveSessions()
            return
        }
        let snapshot = session.persistenceSnapshot
        guard lastSavedSessionSnapshots?[index] != snapshot else { return }
        lastSavedSessionSnapshots?[index] = snapshot
        let persistence = persistence
        sessionPersistenceQueue.async {
            persistence.saveSession(snapshot, sortOrder: index)
        }
    }

    func saveWorkspace() {
        workspaceSaveTask?.cancel()
        persistence.saveWorkspace(workspaceSnapshot())
    }

    func saveWorkspaceSoon() {
        workspaceSaveTask?.cancel()
        let persistence = persistence
        let snapshot = workspaceSnapshot()
        workspaceSaveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            persistence.saveWorkspace(snapshot)
        }
    }

    private func workspaceSnapshot() -> WorkspaceSnapshot {
        WorkspaceSnapshot(
            selectedSessionID: selectedSessionID,
            sortMode: sortMode,
            terminalTheme: terminalTheme,
            terminalFontFamily: terminalFontFamily,
            terminalFontSize: terminalFontSize,
            enableCodexAppServerMode: enableCodexAppServerMode,
            sessionRetentionDays: sessionRetentionDays,
            enableNativeCodex: enableNativeCodex,
            enableHandoffAction: enableHandoffAction,
            autoRetryCodexFailures: autoRetryCodexFailures
        )
    }
}
