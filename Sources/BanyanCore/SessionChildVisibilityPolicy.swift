import Foundation

public struct SessionChildVisibilityItem: Sendable, Equatable {
    public let id: String
    public let parentSessionID: String?
    public let focusLane: SessionFocusLane?

    public init(
        id: String,
        parentSessionID: String?,
        focusLane: SessionFocusLane? = nil
    ) {
        self.id = id
        self.parentSessionID = parentSessionID
        self.focusLane = focusLane
    }
}

/// Decides which hierarchy rows stay visible.
///
/// Folding a parent hides its entire subtree; unfolding shows every child
/// again. Focus scope additionally hides non-actionable rows at every depth,
/// while keeping selected rows and their ancestors visible.
public enum SessionChildVisibilityPolicy {
    /// Filters hierarchy-ordered (parent-first) rows. A folded parent hides
    /// every descendant, including selected sessions and those needing
    /// attention, until the user unfolds it.
    public static func visibleRows(
        rows: [SessionSidebarRow],
        itemsByID: [String: SessionChildVisibilityItem],
        foldedParentIDs: Set<String>,
        selectedID: String? = nil,
        scope: SessionSidebarScope = .all
    ) -> [SessionSidebarRow] {
        var pinnedIDs: Set<String> = []
        if scope == .focus {
            pinnedIDs.formUnion(ancestors(of: selectedID, in: itemsByID))
            if let selectedID { pinnedIDs.insert(selectedID) }
            for item in itemsByID.values where item.focusLane?.isActionable == true {
                pinnedIDs.insert(item.id)
                pinnedIDs.formUnion(ancestors(of: item.id, in: itemsByID))
            }
        }

        func hasFoldedAncestor(_ item: SessionChildVisibilityItem) -> Bool {
            var cursor = item.parentSessionID
            var visited: Set<String> = []
            while let current = cursor, visited.insert(current).inserted {
                if foldedParentIDs.contains(current) { return true }
                cursor = itemsByID[current]?.parentSessionID
            }
            return false
        }

        var visible: [SessionSidebarRow] = []
        var hidden: Set<String> = []
        for row in rows {
            guard let item = itemsByID[row.id] else { continue }
            if let parent = item.parentSessionID, hidden.contains(parent) {
                hidden.insert(row.id)
                continue
            }
            if hasFoldedAncestor(item) {
                hidden.insert(row.id)
                continue
            }
            if pinnedIDs.contains(row.id) {
                visible.append(row)
                continue
            }
            if scope == .focus, item.focusLane?.isActionable != true {
                hidden.insert(row.id)
                continue
            }
            visible.append(row)
        }
        return visible
    }

    private static func ancestors(
        of id: String?,
        in itemsByID: [String: SessionChildVisibilityItem]
    ) -> Set<String> {
        guard let id else { return [] }
        var ancestors: Set<String> = []
        var cursor = itemsByID[id]?.parentSessionID
        while let current = cursor, ancestors.insert(current).inserted {
            cursor = itemsByID[current]?.parentSessionID
        }
        return ancestors
    }
}
