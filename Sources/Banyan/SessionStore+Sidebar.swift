import BanyanCore
import Foundation
import AppKit
import SwiftUI

extension SessionStore {
    var visibleSessions: [BanyanSession] {
        // Exclude closed history before resolving titles and constructing the
        // lookup, rather than making the visibility policy discard it afterwards.
        let active = sessions.filter { $0.status != .closed }
        let items = active.map {
            SessionVisibilityItem(
                id: $0.id,
                status: $0.status,
                updatedAt: $0.updatedAt,
                displayTitle: $0.displayTitle,
                isSuspended: $0.isSuspended
            )
        }
        let sessionsByID = Dictionary(active.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return SessionVisibilityPolicy.visibleIDs(from: items, sortMode: sortMode).compactMap { sessionsByID[$0] }
    }

    /// The sessions with a tmux pane, for work only a terminal has: pane
    /// supervision, liveness sweeps, and terminal rendering.
    var terminalSessions: [TerminalSession] {
        sessions.compactMap { $0 as? TerminalSession }
    }

    /// The visible sessions that render in a terminal pane.
    var visibleTerminalSessions: [TerminalSession] {
        visibleSessions.compactMap { $0 as? TerminalSession }
    }

    var recoverySessions: [BanyanSession] {
        sessions.filter { $0.needsRecovery && !$0.isImportedHistory }
    }

    var sessionSidebarGroups: [SidebarSessionGroup] {
        if sidebarGroupsRevision == cachedSessionSidebarGroupsRevision,
           let cached = cachedSessionSidebarGroups {
            return cached
        }
        let active = visibleSessions.filter { !$0.isImportedHistory }
        let candidates = active.map {
            SessionSidebarCandidate(
                id: $0.id,
                groupID: $0.projectGroupID,
                groupTitle: $0.projectGroupTitle,
                parentSessionID: $0.parentSessionID
            )
        }
        let sessionsByID = Dictionary(active.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let workSummaries = sessionWorkSummaries
        let visibilityInfo = active.map {
            SessionChildVisibilityItem(
                id: $0.id,
                parentSessionID: $0.parentSessionID,
                focusLane: workSummaries[$0.id]?.own.focusLane ?? .forSessionStatus($0.status)
            )
        }
        let visibilityByID = Dictionary(
            visibilityInfo.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let result: [SidebarSessionGroup] = SessionSidebarGroupingPolicy.groups(for: candidates).compactMap { group -> SidebarSessionGroup? in
            let rowIDs = Set(group.rows.map(\.id))
            let moveItems = group.rows.compactMap { row -> SessionSelectionItem? in
                guard let session = sessionsByID[row.id] else { return nil }
                return SessionSelectionItem(id: session.id, parentSessionID: session.parentSessionID)
            }
            let moveOptionsByID = SessionSidebarMovePolicy.optionsByID(in: moveItems)
            let parentsInGroup = Set(
                group.rows.compactMap { visibilityByID[$0.id]?.parentSessionID }
                    .filter { rowIDs.contains($0) }
            )
            let visibleRows = SessionChildVisibilityPolicy.visibleRows(
                rows: group.rows,
                itemsByID: visibilityByID,
                foldedParentIDs: foldedParentIDs,
                selectedID: selectedSessionID,
                scope: sidebarScope
            )
            guard !visibleRows.isEmpty else { return nil }
            return SidebarSessionGroup(
                id: group.id,
                title: group.title,
                items: visibleRows.compactMap { row in
                    guard let session = sessionsByID[row.id] else { return nil }
                    return SidebarSessionItem(
                        session: session,
                        depth: row.depth,
                        isParent: parentsInGroup.contains(row.id),
                        isFolded: foldedParentIDs.contains(row.id),
                        moveOptions: moveOptionsByID[row.id] ?? []
                    )
                },
                moveItems: moveItems
            )
        }
        let visibleIDs = Set(result.flatMap(\.items).map(\.id))
        cachedHiddenSessionCount = active.filter {
            !visibleIDs.contains($0.id) && $0.status != .closed
        }.count
        cachedSessionSidebarGroupsRevision = sidebarGroupsRevision
        cachedSessionSidebarGroups = result
        return result
    }

    /// Live rows the current sidebar projection is not showing, whether because
    /// Focus suppressed non-actionable work or a parent is folded.
    var hiddenSessionCount: Int {
        _ = sessionSidebarGroups
        return cachedHiddenSessionCount
    }

    var historySidebarGroup: SidebarSessionGroup? {
        let historyItems = sidebarHistoryItems
        guard !historyItems.isEmpty else { return nil }
        return SidebarSessionGroup(
            id: "history",
            title: "History",
            items: historyItems
        )
    }

    var sidebarGroups: [SidebarSessionGroup] {
        var groups = sessionSidebarGroups
        if let historySidebarGroup {
            groups.append(historySidebarGroup)
        }
        return groups
    }

    /// Combined active + history groups for the unified sessions sidebar.
    ///
    /// With no search query this is the project-grouped active sessions followed
    /// by the history group, so the whole list scrolls together and active rows
    /// sit above history. With a query it returns a single filtered group of every
    /// matching session (active and history) for a full-text title search.
    var unifiedSidebarGroups: [SidebarSessionGroup] {
        let query = historyFilterText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            var groups = sessionSidebarGroups
            if let history = historySidebarGroup {
                groups.append(history)
            }
            return groups
        }
        let matches = searchSidebarItems(query: query)
        guard !matches.isEmpty else { return [] }
        return [SidebarSessionGroup(id: "search", title: "Search", items: matches)]
    }

    /// Equivalent to `unifiedSidebarGroups.flatMap(\.items).contains`, but
    /// stops at the matching group instead of copying every history row.
    func unifiedSidebarContains(sessionID: String) -> Bool {
        for group in unifiedSidebarGroups {
            if group.items.contains(where: { $0.id == sessionID }) {
                return true
            }
        }
        return false
    }

    private func searchSidebarItems(query: String) -> [SidebarSessionItem] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }
        var ranked: [(item: SidebarSessionItem, updatedAt: Date)] = []
        for session in sessions {
            let isHistory = SessionHistoryPolicy.isLocalHistorySession(
                status: session.status,
                isImportedHistory: session.isImportedHistory,
                provider: session.agentProvider,
                hasIssueLink: session.titleLinkLabel != nil
            ) || session.isImportedHistory
            let composed = SessionHistoryPresentation.sidebarTitle(
                projectName: session.projectName,
                displayTitle: session.displayTitle,
                issueID: session.titleLinkLabel
            )
            guard SessionHistoryPresentation.matchesFilter(title: composed, query: normalized) else { continue }
            let item = SidebarSessionItem(
                session: session,
                depth: 0,
                titleOverride: isHistory ? composed : nil,
                isHistory: isHistory
            )
            ranked.append((item, session.updatedAt))
        }
        ranked.sort { $0.updatedAt > $1.updatedAt }
        return ranked.map { $0.item }
    }

    var sidebarSessions: [SidebarSessionItem] {
        sidebarGroups.flatMap(\.items)
    }

    /// The first `limit` visible sidebar IDs in display order. Menu shortcuts
    /// only need a handful of rows, so avoid flattening the full history group
    /// (which can hold thousands of rows) on every app body pass.
    func sidebarSessionIDs(limit: Int) -> [String] {
        var ids: [String] = []
        ids.reserveCapacity(limit)
        for group in sidebarGroups {
            for item in group.items {
                ids.append(item.id)
                if ids.count >= limit { return ids }
            }
        }
        return ids
    }

    var hasLocalHistorySessions: Bool {
        sessions.contains { session in
            SessionHistoryPolicy.isLocalHistorySession(
                status: session.status,
                isImportedHistory: session.isImportedHistory,
                provider: session.agentProvider,
                hasIssueLink: session.titleLinkLabel != nil
            )
        }
    }

    /// Invalidates the history projection only for rows that can affect it.
    /// Live-session churn (status, output, model identity) is intentionally
    /// ignored: those rows are not in History, and their eventual close bumps
    /// the revision when the row becomes history.
    func noteSidebarHistoryChange(for session: BanyanSession) {
        EnergyTrace.count("sidebar.historyCheck", sessionID: session.id)
        guard !session.isImportedHistory else { return }
        guard session.status == .closed || sidebarHistorySessionIDs.contains(session.id) else { return }
        EnergyTrace.count("sidebar.historyInvalidate", sessionID: session.id)
        sidebarHistoryRevision &+= 1
    }

    private var sidebarHistoryItems: [SidebarSessionItem] {
        let filterText = historyFilterText
        if sidebarHistoryRevision == cachedSidebarHistoryRevision,
           filterText == cachedSidebarHistoryFilterText,
           let cached = cachedSidebarHistoryItems {
            return cached
        }

        let historySessions = sessions.filter { session in
            SessionHistoryPolicy.isLocalHistorySession(
                status: session.status,
                isImportedHistory: session.isImportedHistory,
                provider: session.agentProvider,
                hasIssueLink: session.titleLinkLabel != nil
            )
        }

        // Browse path pre-limits by `updatedAt` before rendering titles;
        // search path must be exhaustive because it matches against composed titles.
        let normalizedQuery = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        let rendered: [BanyanSession]
        if normalizedQuery.isEmpty {
            rendered = historySessions
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(SessionHistoryPresentation.sidebarBrowseLimit)
                .map { $0 }
        } else {
            rendered = historySessions
        }

        let candidates = rendered
            .map { session in
                SessionHistorySidebarCandidate(
                    id: session.id,
                        projectName: session.projectName,
                        displayTitle: session.displayTitle,
                    issueID: session.titleLinkLabel,
                    updatedAt: session.updatedAt
                )
            }
        let sessionsByID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let result: [SidebarSessionItem] = SessionHistoryPresentation.sidebarEntries(
            from: candidates,
            query: filterText
        ).compactMap { entry in
            guard let session = sessionsByID[entry.id] else { return nil }
            return SidebarSessionItem(session: session, depth: 0, titleOverride: entry.title, isHistory: true)
        }
        sidebarHistorySessionIDs = Set(historySessions.map(\.id))
        cachedSidebarHistoryRevision = sidebarHistoryRevision
        cachedSidebarHistoryFilterText = filterText
        cachedSidebarHistoryItems = result
        return result
    }

    var selectedSession: BanyanSession? {
        guard let selectedSessionID else { return nil }
        return sessions.first { $0.id == selectedSessionID }
    }

    var hasScratchTerminal: Bool {
        scratchSession != nil
    }

    var pendingCloseSession: BanyanSession? {
        guard let pendingCloseSessionID else { return nil }
        return sessions.first { $0.id == pendingCloseSessionID }
    }

    var pendingCloseHasActiveChildren: Bool {
        guard let pendingCloseSessionID else { return false }
        return hasActiveChildren(pendingCloseSessionID)
    }

    var pendingCloseHasOngoingAgent: Bool {
        guard let session = pendingCloseSession, session.closeEndsAgentWork else { return false }
        return SessionLifecyclePolicy.isOngoingCodingAgentSession(
            status: session.status,
            provider: session.agentProvider
        )
    }

    func select(id: String) {
        userSelect(id: id)
    }

    /// Explicit user-initiated selection (click, shortcut, palette, nav).
    /// A parked session auto-resumes so the user lands in a live terminal.
    /// Programmatic selection (close/remove/restore) must keep writing
    /// `selectedSessionID`/`selection` directly so a parked neighbor is not
    /// woken by accident.
    func userSelect(id: String) {
        do { try revealBackgroundConversation(id: id) }
        catch { backgroundPresentationError = "The conversation could not be restored. Check local presentation storage and retry."; return }
        if let session = sessions.first(where: { $0.id == id }), session.isSuspended {
            try? resume(id: id)
        }
        // An explicitly selected session must stay visible: lift its ancestors
        // out of the collapsed set so the row does not hide again.
        expandAncestors(of: id)
        selection.selectedSessionID = id
    }

    func expandAncestors(of id: String) {
        // Fast path: top-level sessions have no ancestors to lift.
        guard sessions.first(where: { $0.id == id })?.parentSessionID != nil else { return }
        let sessionsByID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var cursor = sessionsByID[id]?.parentSessionID
        var visited: Set<String> = []
        while let current = cursor, visited.insert(current).inserted {
            foldedParentIDs.remove(current)
            cursor = sessionsByID[current]?.parentSessionID
        }
    }

    /// Flips a parent between folded and unfolded child rows.
    func toggleChildrenFolded(for parentID: String) {
        if foldedParentIDs.contains(parentID) {
            foldedParentIDs.remove(parentID)
        } else {
            foldedParentIDs.insert(parentID)
        }
    }

    /// The selected parent's child fold state, or nil when the selection is not
    /// an active parent in the Sessions sidebar.
    var selectedSessionChildrenFoldState: Bool? {
        guard sidebarMode == .sessions,
              let selectedSessionID,
              sessionSidebarGroups.contains(where: { group in
                  group.items.contains { $0.id == selectedSessionID && $0.isParent }
              }) else {
            return nil
        }
        return foldedParentIDs.contains(selectedSessionID)
    }

    /// Sets the selected parent's child fold state. Returns false when the
    /// selection has no children, so the shortcut can fall through unchanged.
    @discardableResult
    func setSelectedSessionChildrenFolded(_ folded: Bool) -> Bool {
        guard let selectedSessionID,
              selectedSessionChildrenFoldState != nil else {
            return false
        }
        if folded {
            foldedParentIDs.insert(selectedSessionID)
        } else {
            foldedParentIDs.remove(selectedSessionID)
        }
        return true
    }

    private func applySidebarSessionOrder(activeSidebarIDs: [String], reorderedIDs: [String]) {
        let sessionsByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        let reorderedSidebarSessions = reorderedIDs.compactMap { sessionsByID[$0] }
        guard reorderedSidebarSessions.count == reorderedIDs.count else { return }

        let activeSidebarIDSet = Set(activeSidebarIDs)
        let activeSidebarIndices = sessions.indices.filter { activeSidebarIDSet.contains(sessions[$0].id) }
        guard activeSidebarIndices.count == reorderedSidebarSessions.count else { return }

        var nextSessions = sessions
        for (index, session) in zip(activeSidebarIndices, reorderedSidebarSessions) {
            nextSessions[index] = session
        }

        sessions = nextSessions
        sortMode = .manual
        saveSessions()
    }

    /// Applies one hierarchy or sibling-order change. Context-menu commands and
    /// drag/drop both route through this method after resolving a target zone.
    func moveSidebarSession(
        _ sourceID: String,
        command: SessionSidebarMoveCommand,
        in groupID: String
    ) {
        guard let group = sidebarMoveGroup(for: groupID),
              let result = SessionSidebarMovePolicy.move(
                sourceID: sourceID,
                command: command,
                in: group.moveItems
              ),
              let session = sessions.first(where: { $0.id == sourceID }),
              isValidSidebarMoveParent(for: sourceID, parentID: result.parentSessionID) else {
            return
        }

        let currentIDs = group.moveItems.map(\.id)
        let parentChanged = session.parentSessionID != result.parentSessionID
        let orderChanged = result.orderedIDs != currentIDs
        guard parentChanged || orderChanged else { return }

        if parentChanged {
            session.parentSessionID = result.parentSessionID
            if let parentID = result.parentSessionID {
                // A drop onto or an indent under a folded parent should reveal
                // the moved session immediately rather than hiding the result.
                foldedParentIDs.remove(parentID)
            }
        }
        if orderChanged {
            applySidebarSessionOrder(
                activeSidebarIDs: currentIDs,
                reorderedIDs: result.orderedIDs
            )
        } else {
            sidebarGroupsRevision &+= 1
            sortMode = .manual
            objectWillChange.send()
            saveSessions()
        }
    }

    func canMoveSidebarSession(
        _ sourceID: String,
        command: SessionSidebarMoveCommand,
        in groupID: String
    ) -> Bool {
        guard let group = sidebarMoveGroup(for: groupID),
              let result = SessionSidebarMovePolicy.move(
                sourceID: sourceID,
                command: command,
                in: group.moveItems
              ),
              let session = sessions.first(where: { $0.id == sourceID }),
              isValidSidebarMoveParent(for: sourceID, parentID: result.parentSessionID) else {
            return false
        }
        return session.parentSessionID != result.parentSessionID ||
            group.moveItems.map(\.id) != result.orderedIDs
    }

    private func sidebarMoveGroup(for groupID: String) -> SidebarSessionGroup? {
        sessionSidebarGroups.first { $0.id == groupID }
    }

    private func isValidSidebarMoveParent(for sourceID: String, parentID: String?) -> Bool {
        do {
            _ = try SessionRelationshipPolicy.validatedParentID(
                for: sourceID,
                proposedParentID: parentID,
                in: reparentingItems
            )
            return true
        } catch {
            return false
        }
    }
}
