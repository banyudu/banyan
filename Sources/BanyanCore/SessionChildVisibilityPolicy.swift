import Foundation

public struct SessionChildVisibilityItem: Sendable, Equatable {
    public let id: String
    public let parentSessionID: String?
    public let status: SessionStatus
    public let isSuspended: Bool

    public init(
        id: String,
        parentSessionID: String?,
        status: SessionStatus,
        isSuspended: Bool = false
    ) {
        self.id = id
        self.parentSessionID = parentSessionID
        self.status = status
        self.isSuspended = isSuspended
    }
}

/// Decides which parent/child hierarchy rows stay visible when parents are
/// collapsed and finished children are hidden.
///
/// Top-level rows (depth 0) are never hidden by this policy — only children
/// collapse away, so a parent is always there to expand.
public enum SessionChildVisibilityPolicy {
    /// Terminal children hidden by the "show finished" toggle. Deliberately
    /// completed-only: a failed session needs a human decision (see
    /// `SessionLifecyclePolicy.needsAttention`), so it always stays visible.
    public static func isFinishedHidden(status: SessionStatus) -> Bool {
        status == .completed
    }

    /// A collapsed parent still reveals children that need a human right now.
    /// Parked sessions never peek: nothing observes them, so a parked status
    /// is frozen and would otherwise compete for attention forever.
    public static func peeksThrough(status: SessionStatus, isSuspended: Bool) -> Bool {
        guard !isSuspended else { return false }
        return [.asking, .needInput, .failed].contains(status)
    }

    /// Parents whose whole subtree is finished or parked start collapsed, so a
    /// finished worktree of child sessions does not spend a row per child.
    /// Anything live (running, idle, asking, …) keeps its parent expanded, and
    /// the selected session's ancestry never auto-collapses.
    public static func autoCollapsedParents(
        in items: [SessionChildVisibilityItem],
        selectedID: String? = nil
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
                if item.status != .completed, item.status != .closed, !item.isSuspended {
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
    /// for finished-hidden children under an expanded parent.
    public static func visibleRows(
        rows: [SessionSidebarRow],
        itemsByID: [String: SessionChildVisibilityItem],
        collapsedParentIDs: Set<String>,
        showFinishedChildren: Bool,
        selectedID: String? = nil
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
            if row.depth == 0 {
                visible.append(row)
                continue
            }
            if let parent = item.parentSessionID, hidden.contains(parent) {
                hide(rowID: row.id, item: item)
                continue
            }
            if row.id == selectedID || selectedAncestors.contains(row.id) {
                visible.append(row)
                continue
            }
            if !showFinishedChildren, isFinishedHidden(status: item.status) {
                hide(rowID: row.id, item: item)
                continue
            }
            if nearestCollapsedAncestor(of: item) != nil {
                if peeksThrough(status: item.status, isSuspended: item.isSuspended) {
                    visible.append(row)
                } else {
                    hide(rowID: row.id, item: item)
                }
                continue
            }
            visible.append(row)
        }
        return (visible, hiddenCountByParentID)
    }
}
