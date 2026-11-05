import BanyanCore
import Foundation
import AppKit
import SwiftUI

extension SessionStore {
    func restart(id: String) throws {
        guard let session = sessions.first(where: { $0.id == id }) else {
            throw ControlError.notFound(id)
        }
        guard session.canRestart, let session = session as? TerminalSession else {
            throw ControlError.badRequest("session '\(id)' has no launch command to restart")
        }
        try prepareAgentResumeForRestart(session)
        try session.prepareFrozenAgentForTeardown()
        session.agentLaunchQueue = nil
        unparkForAttach(session)
        session.restartBackingSession()
        selectedSessionID = id
        saveSessions()
    }

    /// Parks a session outside Banyan's supervision and render budget. The tmux
    /// session and whatever agent is running inside it are left completely alone,
    /// so this is neither `close` (which kills the backing session) nor a
    /// SIGSTOP of the agent — only Banyan stops paying for it.
    func suspend(id: String) throws {
        guard let session = sessions.first(where: { $0.id == id }) else {
            throw ControlError.notFound(id)
        }
        guard !session.isImportedHistory else {
            throw ControlError.badRequest("cannot suspend imported history '\(id)'")
        }
        guard session.status != .closed else {
            throw ControlError.badRequest("cannot suspend closed session '\(id)'")
        }
        guard !session.isSuspended else { return }

        if let native = session as? CodexSession,
           native.state.runtime.type == "active" || native.state.activeTurnID != nil || native.state.needsAttention {
            throw ControlError.badRequest("Finish the active Codex turn and pending requests before parking this session")
        }
        fenceSlackInput(for: session)
        session.suspend()
        // Its backoff state describes a session nothing is observing any more.
        supervisorObservationStates.removeValue(forKey: id)
        // The selection deliberately stays put: the parked banner over the frozen
        // pane says what happened and offers Resume, which reads better than
        // silently moving the user to some other session.
        if selectedSessionID == id {
            refreshSelectedContextInfo(force: true)
        }
        saveSessions()
        // One fewer started session may mean a different cadence.
        rescheduleSupervisor()
    }

    /// Returns a parked session to the working set and re-observes it at once, so
    /// the sidebar shows what the agent actually did while Banyan was not watching.
    func resume(id: String) throws {
        guard let session = sessions.first(where: { $0.id == id }) else {
            throw ControlError.notFound(id)
        }
        guard session.isSuspended else { return }

        // Parking never touched the agent, so whatever was last observed is still
        // the truth. Attaching a client optimistically marks `.running`, which
        // would otherwise flick the row through a state it was never in.
        let observedStatus = session.status
        let observedTone = session.tone
        session.resume()
        retainManagedNativeObservation(session)
        if let terminal = session as? TerminalSession,
           !terminal.needsRecovery, terminal.loadedTerminalView != nil {
            // `onTerminalReady` fires once per container and this session already
            // has one, so nothing else would rebuild the client from the live pane.
            terminal.reattachTerminalClient()
            terminal.status = observedStatus
            terminal.tone = observedTone
            terminal.touch()
        }
        resetSupervisorObservationBackoff(for: id)
        if selectedSessionID == id {
            refreshSelectedContextInfo(force: true)
        }
        runSupervisorTick(sessionID: id)
        if session is PuckSession {
            syncPuckSessions()
        }
        if let native = session as? CodexSession {
            native.reconnect()
        }
        saveSessions()
        rescheduleSupervisor()
    }

    /// `respawn`, `recover` and `restart` all mean "put this session back to
    /// work", which is the opposite of parked. Each then attaches a client and
    /// sets its own runtime state, so this only has to drop the gate — otherwise
    /// they would leave a row claiming to be parked while its client attaches.
    func unparkForAttach(_ session: BanyanSession) {
        resumeFrozenForInteraction(id: session.id)
        guard session.isSuspended else { return }
        session.isSuspended = false
        retainManagedNativeObservation(session)
        supervisorObservationStates.removeValue(forKey: session.id)
    }

    func setSuspended(id: String, suspended: Bool) throws {
        try suspended ? suspend(id: id) : resume(id: id)
    }

    func toggleSuspended(id: String) throws {
        guard let session = sessions.first(where: { $0.id == id }) else {
            throw ControlError.notFound(id)
        }
        try setSuspended(id: id, suspended: !session.isSuspended)
    }

    /// Nothing observes a parked session, so a tmux session that exits while it is
    /// parked would otherwise go unnoticed until the user resumed it. This costs one
    /// `tmux list-sessions` for the whole set — independent of how many are parked —
    /// so it rides the existing supervisor timer instead of needing its own.
    func sweepSuspendedSessionLivenessIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(lastSuspendedLivenessSweepAt) >= Self.suspendedLivenessSweepInterval else {
            return
        }
        let parked = terminalSessions.filter { $0.isSuspended && $0.status != .closed && !$0.needsRecovery }
        guard !parked.isEmpty else { return }
        lastSuspendedLivenessSweepAt = now

        let backend = tmuxBackend
        Task.detached(priority: .background) { [weak self] in
            let liveNames = Set(backend.listBanyanSessions())
            await MainActor.run { [weak self] in
                guard let self else { return }
                var didUpdate = false
                for session in self.terminalSessions where session.isSuspended && !session.needsRecovery {
                    guard SessionLifecyclePolicy.shouldMarkForRecovery(
                        status: session.status,
                        tmuxSessionName: session.tmuxSessionName,
                        liveTmuxSessionNames: liveNames
                    ) else { continue }
                    session.needsRecovery = true
                    session.touch()
                    didUpdate = true
                }
                if didUpdate {
                    self.saveSessions()
                }
            }
        }
    }

    func mark(id: String, status: SessionStatus? = nil, tone: SessionTone? = nil, title: String? = nil, titleURL: String? = nil) throws {
        guard let session = sessions.first(where: { $0.id == id }) else {
            throw ControlError.notFound(id)
        }
        session.mark(status: status, tone: tone, title: title, titleURL: SessionInputPolicy.normalizedTitleURL(titleURL))
        saveSessions()
    }

    @discardableResult
    func updateContextualTitle(id: String, title: String) throws -> Bool {
        guard let session = sessions.first(where: { $0.id == id }) else {
            throw ControlError.notFound(id)
        }
        guard SessionTitleMCP.normalizedTitle(title) != nil else {
            throw ControlError.badRequest("A specific session title is required")
        }
        let applied = session.updateContextualTitle(title)
        if applied { saveChangedSession(session) }
        return applied
    }

    func close(id: String) throws {
        try close(id: id, force: false)
    }

    /// Explicitly closes despite a workflow/recovery hold. This does not
    /// modify the workflow owner state or its journal.
    func forceClose(id: String) throws {
        try close(id: id, force: true)
    }

    func close(id: String, force: Bool) throws {
        guard let session = sessions.first(where: { $0.id == id }) else {
            throw ControlError.notFound(id)
        }
        if !force {
            guard session.workflow?.state.permitsClose != false, session.workflowRecoveryError == nil else {
                throw ControlError.conflict(code: "workflow_unfinished", message: "Issue is unfinished; verify it or explicitly pause/cancel its workflow before closing")
            }
        }
        guard !pauseCloseInFlightIDs.contains(id) else {
            throw WorkflowError.refused("Pause and Close is in progress; wait for the owner acknowledgement and matching projection.")
        }
        if !force {
            // Re-read at the destructive boundary: a previously readable journal
            // must not authorize teardown after corruption or a projection change.
            do {
                guard try workflowJournal.load(id: id) == session.workflow else {
                    throw WorkflowError.refused("workflow journal differs from the current projection")
                }
            } catch {
                throw WorkflowError.refused("The workflow journal cannot confirm close. Repair it or have its owner project the current workflow, then retry. The terminal remains open.")
            }
        }
        try (session as? TerminalSession)?.prepareFrozenAgentForTeardown()
        let replacementID = selectedSessionID == id
            ? preferredSelectionAfterClosing(id: id)
            : nil
        let promotedChildIDs = detachChildren(of: id, to: session.parentSessionID)
        fenceSlackInput(for: session)
        if session.isImportedHistory {
            session.terminate(markClosed: true)
        } else {
            session.closeBackingSession()
        }
        // Closing is a deliberate history event. The normal activity timestamp
        // is coalesced, so stamp it here to put this row first even if the
        // session produced output in the preceding two seconds.
        session.updatedAt = Date()
        promoteChildrenToParentSlot(closingID: id, promotedChildIDs: promotedChildIDs, removingParent: false)
        pauseCloseAttempts[id] = nil
        if pauseCloseRetrySessionID == id { pauseCloseRetrySessionID = nil }
        if selectedSessionID == id {
            selectedSessionID = replacementID ?? visibleSessions.first?.id
        }
        saveSessions()
    }

    func remove(id: String) throws {
        guard !codexRemote.attachments.contains(where: { $0.sessionID == id }) else {
            throw ControlError.badRequest("Detach Slack before removing this native session")
        }
        guard let index = sessions.firstIndex(where: { $0.id == id }) else {
            throw ControlError.notFound(id)
        }
        try (sessions[index] as? TerminalSession)?.prepareFrozenAgentForTeardown()
        if let native = sessions[index] as? CodexSession,
           native.state.runtime.type == "active" || native.state.activeTurnID != nil || native.state.needsAttention {
            throw ControlError.badRequest("Finish the active Codex turn and answer pending requests before removing this session. Close it to history if you need to hide it; it can still be reopened.")
        }
        let replacementID = selectedSessionID == id
            ? preferredSelectionAfterClosing(id: id)
            : nil
        fenceSlackInput(for: sessions[index])
        if sessions[index].isImportedHistory {
            sessions[index].status = .closed
            if selectedSessionID == id {
                selectedSessionID = replacementID ?? visibleSessions.first?.id
            }
            return
        }
        let parentSessionID = sessions[index].parentSessionID
        let promotedChildIDs = detachChildren(of: id, to: parentSessionID)
        if sessions[index] is PuckSession {
            dismissedPuckSessionIDs.insert(id)
        }
        sessions[index].closeBackingSession()
        sessions[index].updatedAt = Date()
        promoteChildrenToParentSlot(closingID: id, promotedChildIDs: promotedChildIDs, removingParent: true)
        if selectedSessionID == id {
            selectedSessionID = replacementID ?? visibleSessions.first?.id
        }
        saveSessions()
    }

    func requestClose(id: String) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        // Every close is confirmed, whatever the backend: the dialog is where
        // the consequence is spelled out (kill a running agent, detach
        // children, or just drop a daemon session from the sidebar), and the
        // close chord is easy to hit by accident.
        pendingCloseSessionID = id
    }

    func confirmPendingClose() {
        guard let id = pendingCloseSessionID, !pauseCloseInFlightIDs.contains(id) else { return }
        pendingCloseSessionID = nil
        do { try close(id: id) }
        catch {
            pauseCloseRetrySessionID = nil
            pauseCloseError = error.localizedDescription
        }
    }

    func cancelPendingClose() {
        pendingCloseSessionID = nil
    }

    func activeChildCount(of id: String) -> Int {
        SessionRelationshipPolicy.activeChildCount(
            of: id,
            in: sessions.map {
                SessionRelationshipItem(
                    id: $0.id,
                    parentSessionID: $0.parentSessionID,
                    status: $0.status
                )
            }
        )
    }

    func hasActiveChildren(_ id: String) -> Bool {
        activeChildCount(of: id) > 0
    }

    var reparentingItems: [SessionRelationshipItem] {
        sessions.map {
            SessionRelationshipItem(id: $0.id, parentSessionID: $0.parentSessionID,
                status: $0.status, isImportedHistory: $0.isImportedHistory,
                projectGroupID: $0.projectGroupID)
        }
    }

    @discardableResult
    func reparent(id: String, parentSessionID: String?) throws -> BanyanSession {
        let parentID = try SessionRelationshipPolicy.validatedParentID(
            for: id, proposedParentID: parentSessionID, in: reparentingItems)
        guard let session = sessions.first(where: { $0.id == id }) else { throw ControlError.notFound(id) }
        guard session.parentSessionID != parentID else { return session }
        session.parentSessionID = parentID
        // Do not touch timestamps, selection, collapse state, or the backing process.
        objectWillChange.send()
        saveSessions()
        return session
    }

    /// Include collapsed/hidden active targets, in the same hierarchy used by the sidebar.
    func reparentTargets(for sourceID: String) -> [SidebarSessionItem] {
        guard let source = sessions.first(where: { $0.id == sourceID }),
              source.status != .closed, !source.isImportedHistory else { return [] }
        let active = visibleSessions.filter { !$0.isImportedHistory && $0.projectGroupID == source.projectGroupID }
        let byID = Dictionary(active.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let validParentIDs = SessionRelationshipPolicy.validParentIDs(for: sourceID, in: reparentingItems)
        return SessionSidebarHierarchyPolicy.rows(for: active.map {
            SessionSelectionItem(id: $0.id, parentSessionID: $0.parentSessionID)
        }).compactMap { row in
            guard let session = byID[row.id], validParentIDs.contains(row.id) else { return nil }
            return SidebarSessionItem(session: session, depth: row.depth)
        }
    }

    func resolvedParentSessionIDForSpawn(_ parentSessionID: String?) throws -> String? {
        guard let normalizedParentID = SessionInputPolicy.normalizedOptionalText(parentSessionID) else {
            return nil
        }
        let activeSessionIDs = Set(sessions.filter { $0.status != .closed }.map(\.id))
        guard let resolvedID = SessionRelationshipPolicy.resolvedActiveParentID(
            normalizedParentID,
            activeSessionIDs: activeSessionIDs
        ) else {
            throw ControlError.badRequest("No active parent session found for id '\(normalizedParentID)'")
        }
        return resolvedID
    }

    /// Chooses the nearest session before the closing session is removed.
    /// Sidebar groups are already in their rendered order, so this preserves the
    /// user's project/session navigation order across all sort modes.
    ///
    /// Include active rows hidden by collapsed/finished filtering: closing
    /// their parent promotes them into the visible tree. Falling back to the
    /// global session list instead can jump to another project while rows from
    /// the closing project remain.
    private func preferredSelectionAfterClosing(id: String) -> String? {
        let active = visibleSessions.filter { !$0.isImportedHistory }
        let parentByID = Dictionary(
            active.map { ($0.id, $0.parentSessionID) },
            uniquingKeysWith: { first, _ in first }
        )
        let groups = SessionSidebarGroupingPolicy.groups(for: active.map {
            SessionSidebarCandidate(
                id: $0.id,
                groupID: $0.projectGroupID,
                groupTitle: $0.projectGroupTitle,
                parentSessionID: $0.parentSessionID
            )
        }).map { group in
            SessionSelectionGroup(
                id: group.id,
                items: group.rows.map { row in
                    SessionSelectionItem(
                        id: row.id,
                        parentSessionID: parentByID[row.id] ?? nil
                    )
                }
            )
        }
        return SessionClosingSelectionPolicy.preferredIDAfterClosing(
            closingID: id,
            groups: groups
        )
    }

    /// Detaches a closing session's direct children up one tree level, to the
    /// closing session's own parent. Returns the promoted child IDs in
    /// sessions order. Grandchildren stay under their parents, so the whole
    /// subtree moves up exactly one level.
    @discardableResult
    private func detachChildren(of parentID: String, to newParentID: String?) -> [String] {
        let parentIDForChildren = SessionChildPromotionPolicy.promotedParentID(
            closingParentID: newParentID
        )
        var promotedChildIDs: [String] = []
        for session in sessions where session.parentSessionID == parentID {
            session.parentSessionID = parentIDForChildren
            session.touch()
            promotedChildIDs.append(session.id)
        }
        return promotedChildIDs
    }

    /// Moves promoted children into the closing session's slot in manual
    /// order, so closing `B` in `A, B(B1, B2), C` reads `A, B1, B2, C`
    /// instead of stranding the children where they were appended (`A, C,
    /// B1, B2`). With `removingParent` the closing row is dropped from the
    /// array as well (`remove`); otherwise it stays as a hidden closed row
    /// (`close`). Non-manual sort modes re-sort for display anyway, so this
    /// only affects manual order and its persisted `sort_order`.
    private func promoteChildrenToParentSlot(
        closingID: String,
        promotedChildIDs: [String],
        removingParent: Bool
    ) {
        let orderedIDs = sessions.map(\.id)
        let reordered: [String]?
        if promotedChildIDs.isEmpty {
            reordered = removingParent ? orderedIDs.filter { $0 != closingID } : nil
        } else {
            reordered = SessionChildPromotionPolicy.reorderedIDs(
                orderedIDs: orderedIDs,
                closingID: closingID,
                promotedChildIDs: promotedChildIDs,
                removingParent: removingParent
            )
        }
        guard let reordered, reordered != orderedIDs else { return }
        let sessionsByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        let next = reordered.compactMap { sessionsByID[$0] }
        guard next.count == reordered.count else { return }
        sessions = next
    }
}
