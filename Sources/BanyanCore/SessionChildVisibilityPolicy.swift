import Foundation

public struct SessionChildVisibilityItem: Sendable, Equatable {
    public let id: String
    public let parentSessionID: String?
    public let status: SessionStatus
    public let isSuspended: Bool
    public let focusLane: SessionFocusLane?

    public init(
        id: String,
        parentSessionID: String?,
        status: SessionStatus,
        isSuspended: Bool = false,
        focusLane: SessionFocusLane? = nil
    ) {
        self.id = id
        self.parentSessionID = parentSessionID
        self.status = status
        self.isSuspended = isSuspended
        self.focusLane = focusLane
    }
}

/// Decides which parent/child hierarchy rows stay visible when parents are
/// collapsed and finished children are hidden.
///
/// Top-level rows remain visible in the all-sessions scope. Focus additionally
/// hides managed watch/settled work, including top-level work, while retaining
/// selected sessions and sessions that need a human decision.
public enum SessionChildVisibilityPolicy {
    /// Terminal children hidden by the "show finished" toggle. Deliberately
    /// completed-only: a failed session needs a human decision (see
    /// `SessionLifecyclePolicy.needsAttention`), so it is not finished-hidden.
    public static func isFinishedHidden(status: SessionStatus) -> Bool {
        status == .completed
    }

    /// Parents whose whole subtree is finished or parked start collapsed, so a
    /// finished worktree of child sessions does not spend a row per child.
    /// Anything live (running, idle, asking, …) keeps its parent expanded, and
    /// the selected session's ancestry never auto-collapses.
    public static func autoCollapsedParents(
        in items: [SessionChildVisibilityItem],
        selectedID: String? = nil,
        scope: SessionSidebarScope = .all
    ) -> Set<String> {
        let ids = Set(items.map(\.id))
        var childrenByParent: [String: [String]] = [:]
        for item in items {
            if let parent = item.parentSessionID, ids.contains(parent) {
                childrenByParent[parent, default: []].append(item.id)
            }
        }
        guard !childrenByParent.isEmpty else { return [] }
        let itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        var selectedAncestors: Set<String> = []
        if let selectedID {
            var cursor = itemsByID[selectedID]?.parentSessionID
            var visited: Set<String> = []
            while let current = cursor, visited.insert(current).inserted {
                selectedAncestors.insert(current)
                cursor = itemsByID[current]?.parentSessionID
            }
        }
        var result: Set<String> = []
        for parentID in childrenByParent.keys {
            guard parentID != selectedID, !selectedAncestors.contains(parentID) else { continue }
            var stack = childrenByParent[parentID] ?? []
            var visited: Set<String> = [parentID]
            var hasLiveDescendant = false
            while let id = stack.popLast() {
                guard visited.insert(id).inserted else { continue }
                guard let item = itemsByID[id] else { continue }
                let isLive = item.status != .completed && item.status != .closed && !item.isSuspended
                let contributesToFocus = scope == .all || item.focusLane == nil || item.focusLane == .act
                if isLive, contributesToFocus {
                    hasLiveDescendant = true
                    break
                }
                stack.append(contentsOf: childrenByParent[id] ?? [])
            }
            if !hasLiveDescendant {
                result.insert(parentID)
            }
        }
        return result
    }

    /// Filters hierarchy-ordered (parent-first) rows. Returns the rows to
    /// render plus, per row ID, how many descendants were hidden beneath it —
    /// attributed to the nearest collapsed ancestor, or to the direct parent
    /// for finished-hidden children under an expanded parent. Collapsed parents
    /// hide every descendant, including selected sessions and those needing attention.
    public static func visibleRows(
        rows: [SessionSidebarRow],
        itemsByID: [String: SessionChildVisibilityItem],
        collapsedParentIDs: Set<String>,
        showFinishedChildren: Bool,
        selectedID: String? = nil,
        scope: SessionSidebarScope = .all
    ) -> (visible: [SessionSidebarRow], hiddenCountByParentID: [String: Int]) {
        var selectedAncestors: Set<String> = []
        if let selectedID {
            var cursor = itemsByID[selectedID]?.parentSessionID
            var visited: Set<String> = []
            while let current = cursor, visited.insert(current).inserted {
                selectedAncestors.insert(current)
                cursor = itemsByID[current]?.parentSessionID
            }
        }

        var focusPinnedIDs = selectedAncestors
        if let selectedID { focusPinnedIDs.insert(selectedID) }
        if scope == .focus {
            for item in itemsByID.values where item.focusLane == nil || item.focusLane == .act {
                focusPinnedIDs.insert(item.id)
                var cursor = item.parentSessionID
                var visited: Set<String> = []
                while let current = cursor, visited.insert(current).inserted {
                    focusPinnedIDs.insert(current)
                    cursor = itemsByID[current]?.parentSessionID
                }
            }
        }

        func nearestCollapsedAncestor(of item: SessionChildVisibilityItem) -> String? {
            var cursor = item.parentSessionID
            var visited: Set<String> = []
            while let current = cursor, visited.insert(current).inserted {
                if collapsedParentIDs.contains(current) { return current }
                cursor = itemsByID[current]?.parentSessionID
            }
            return nil
        }

        var visible: [SessionSidebarRow] = []
        var hidden: Set<String> = []
        var hiddenCountByParentID: [String: Int] = [:]

        func hide(rowID: String, item: SessionChildVisibilityItem) {
            hidden.insert(rowID)
            if let collapsed = nearestCollapsedAncestor(of: item) {
                hiddenCountByParentID[collapsed, default: 0] += 1
            } else if let parent = item.parentSessionID {
                hiddenCountByParentID[parent, default: 0] += 1
            }
        }

        for row in rows {
            guard let item = itemsByID[row.id] else { continue }
            if let parent = item.parentSessionID, hidden.contains(parent) {
                hide(rowID: row.id, item: item)
                continue
            }
            if nearestCollapsedAncestor(of: item) != nil {
                hide(rowID: row.id, item: item)
                continue
            }
            if row.id == selectedID || selectedAncestors.contains(row.id) {
                visible.append(row)
                continue
            }
            if scope == .focus, let lane = item.focusLane, lane != .act, !focusPinnedIDs.contains(row.id) {
                hide(rowID: row.id, item: item)
                continue
            }
            if row.depth == 0 {
                visible.append(row)
                continue
            }
            if !showFinishedChildren, isFinishedHidden(status: item.status) {
                hide(rowID: row.id, item: item)
                continue
            }
            visible.append(row)
        }
        return (visible, hiddenCountByParentID)
    }
}
