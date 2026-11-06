import BanyanCore
import Foundation
import AppKit
import SwiftUI

extension SessionStore {
    /// Find searches a terminal's scrollback; other sessions have none.
    var canFindInSelectedSession: Bool {
        guard let selectedSession = selectedSession as? TerminalSession else { return false }
        return !selectedSession.isImportedHistory
    }

    func showFindInSelectedSession() {
        guard canFindInSelectedSession,
              let selectedSession = selectedSession as? TerminalSession else { return }
        let item = NSMenuItem()
        item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        selectedSession.terminalView.performFindPanelAction(item)
    }

    func selectNextSession() {
        selectAdjacentSession(direction: .next)
    }

    func selectPreviousSession() {
        selectAdjacentSession(direction: .previous)
    }

    func selectFirstSession() {
        guard let id = sidebarSessions.first?.id else { return }
        userSelect(id: id)
    }

    func selectLastSession() {
        guard let id = sidebarSessions.last?.id else { return }
        userSelect(id: id)
    }

    func selectSessionPage(direction: SessionSelectionDirection, pageSize: Int) {
        guard let id = SessionSelectionNavigator.pagedID(
            in: sidebarSessions.map(\.id),
            selectedID: selection.selectedSessionID,
            direction: direction,
            pageSize: pageSize
        ) else {
            return
        }
        userSelect(id: id)
    }

    func selectNextProject() {
        selectAdjacentProject(direction: .next)
    }

    func selectPreviousProject() {
        selectAdjacentProject(direction: .previous)
    }

    /// Selects the top row of the next or previous project group. Groups wrap,
    /// matching adjacent-session navigation; a selection outside every project
    /// (for example one in History) enters from the corresponding end.
    private func selectAdjacentProject(direction: SessionSelectionDirection) {
        let groups = sessionSidebarGroups
        let selectedGroupID = selection.selectedSessionID.flatMap { selectedID in
            groups.first { group in group.items.contains { $0.id == selectedID } }?.id
        }
        guard let groupID = SessionSelectionNavigator.adjacentID(
            in: groups.map(\.id),
            selectedID: selectedGroupID,
            direction: direction
        ), let targetID = groups.first(where: { $0.id == groupID })?.items.first?.id else {
            return
        }
        userSelect(id: targetID)
    }

    func selectNextLinearIssue() {
        selectAdjacentLinearIssue(direction: .next)
    }

    func selectPreviousLinearIssue() {
        selectAdjacentLinearIssue(direction: .previous)
    }

    private func selectAdjacentLinearIssue(direction: SessionSelectionDirection) {
        let orderedIDs = linearIssueNavigationIDs ?? linearIssues.map(\.identifier)
        guard let issueID = SessionSelectionNavigator.adjacentID(
            in: orderedIDs,
            selectedID: selectedLinearListIssueID,
            direction: direction
        ) else {
            return
        }
        selectedLinearListIssueID = issueID
    }

    func selectNextWorkableSession() {
        guard let id = SessionSelectionNavigator.nextMatchingID(
            in: sidebarSessions.map(\.id),
            selectedID: selection.selectedSessionID,
            isMatch: isWorkableSession
        ) else {
            return
        }
        userSelect(id: id)
    }

    var hasMultipleSidebarSessions: Bool {
        // Menus re-evaluate on each keystroke. Two visible active rows already
        // decide this, without hashing thousands of closed history rows.
        let activeCount = sessionSidebarGroups.reduce(0) { $0 + $1.items.count }
        if activeCount >= 2 { return true }
        return activeCount + (historySidebarGroup?.items.count ?? 0) >= 2
    }

    var hasWorkableSession: Bool {
        // History is closed and cannot be workable. Keep the grouping so hidden
        // children stay excluded, and use the row directly rather than searching
        // the full session array again for each candidate.
        sessionSidebarGroups.contains { group in
            group.items.contains { item in
                SessionLifecyclePolicy.isWorkable(
                    status: item.session.status,
                    isImportedHistory: item.session.isImportedHistory
                )
            }
        }
    }

    func selectNextSessionNeedingAttention() {
        selectSessionNeedingAttention(direction: .next)
    }

    func selectPreviousSessionNeedingAttention() {
        selectSessionNeedingAttention(direction: .previous)
    }

    /// Moves to the nearest idle session or one blocked on a decision, wrapping
    /// around sidebar order. A parent whose subtree holds a waiting question is
    /// skipped so the chord lands where input is actually needed; a parent
    /// with nothing waiting below it stays a stop. The current selection is
    /// excluded, so pressing the chord while sitting on the only eligible
    /// session stays put instead of silently reselecting it.
    func selectSessionNeedingAttention(direction: SessionSelectionDirection) {
        guard let id = SessionSelectionNavigator.matchingID(
            in: sidebarSessions.map(\.id),
            selectedID: selection.selectedSessionID,
            direction: direction,
            includingSelection: false,
            isMatch: isSessionNeedingAttention
        ) else {
            return
        }
        userSelect(id: id)
    }

    var canSelectSessionNeedingAttention: Bool {
        // Evaluated on every menu-bar rebuild — effectively every keystroke.
        // The old form routed through `sidebarSessions` (full grouping over
        // every row, ~3000 with closed history) and then re-scanned all rows
        // per candidate inside `isSessionNeedingAttention`: millions of ops
        // per evaluation, blocking the keystroke. Single pass instead. Closed
        // history can never need attention, and the parent-subtree rule only
        // needs the relationship scan for the rare rows that pass the cheap
        // status gate (built lazily, at most once per evaluation).
        let selectedID = selection.selectedSessionID
        var relationshipItems: [SessionRelationshipItem]?
        for session in sessions {
            guard session.id != selectedID,
                  session.status != .closed,
                  SessionLifecyclePolicy.isAttentionNavigationCandidate(
                      status: session.status,
                      isImportedHistory: session.isImportedHistory,
                      isSuspended: session.isSuspended
                  )
            else { continue }
            if relationshipItems == nil {
                relationshipItems = sessions.map {
                    SessionRelationshipItem(
                        id: $0.id,
                        parentSessionID: $0.parentSessionID,
                        status: $0.status,
                        isImportedHistory: $0.isImportedHistory,
                        isSuspended: $0.isSuspended
                    )
                }
            }
            let waitingBelow = SessionRelationshipPolicy.hasWaitingDescendant(
                of: session.id,
                in: relationshipItems!
            ) {
                SessionLifecyclePolicy.needsAttention(
                    status: $0.status,
                    isImportedHistory: $0.isImportedHistory,
                    isSuspended: $0.isSuspended
                )
            }
            if !waitingBelow { return true }
        }
        return false
    }

    @discardableResult
    func selectSession(shortcutIndex: Int) -> Bool {
        selectSession(shortcutIndex: shortcutIndex, in: NSApp.keyWindow)
    }

    @discardableResult
    func selectSession(shortcutIndex: Int, in window: NSWindow?) -> Bool {
        let id: String?
        if let shortcuts = SessionJumpShortcuts.forWindow(window) {
            id = shortcuts.sessionID(for: shortcutIndex)
        } else {
            id = SessionSelectionNavigator.directID(
                in: sidebarSessions.map(\.id),
                oneBasedIndex: shortcutIndex
            )
        }
        guard let id, sessions.contains(where: { $0.id == id }) else {
            return false
        }
        userSelect(id: id)
        return true
    }

    func requestCloseSelectedSession() {
        guard let selectedSession else { return }
        requestClose(id: selectedSession.id)
    }

    private func selectAdjacentSession(direction: SessionSelectionDirection) {
        guard let id = SessionSelectionNavigator.adjacentID(
            in: sidebarSessions.map(\.id),
            selectedID: selection.selectedSessionID,
            direction: direction
        ) else {
            return
        }
        userSelect(id: id)
    }

    private func isWorkableSession(_ id: String) -> Bool {
        guard let session = sessions.first(where: { $0.id == id }) else { return false }
        return SessionLifecyclePolicy.isWorkable(
            status: session.status,
            isImportedHistory: session.isImportedHistory
        )
    }

    private func isSessionNeedingAttention(_ id: String) -> Bool {
        guard let session = sessions.first(where: { $0.id == id }) else { return false }
        guard SessionLifecyclePolicy.isAttentionNavigationCandidate(
            status: session.status,
            isImportedHistory: session.isImportedHistory,
            isSuspended: session.isSuspended
        ) else {
            return false
        }
        // A parent whose subtree holds the waiting question is skipped so the
        // chord lands where input is actually needed; a parent with nothing
        // waiting below it stays a target.
        let items = sessions.map {
            SessionRelationshipItem(
                id: $0.id,
                parentSessionID: $0.parentSessionID,
                status: $0.status,
                isImportedHistory: $0.isImportedHistory,
                isSuspended: $0.isSuspended
            )
        }
        return !SessionRelationshipPolicy.hasWaitingDescendant(of: id, in: items) {
            SessionLifecyclePolicy.needsAttention(
                status: $0.status,
                isImportedHistory: $0.isImportedHistory,
                isSuspended: $0.isSuspended
            )
        }
    }
}
