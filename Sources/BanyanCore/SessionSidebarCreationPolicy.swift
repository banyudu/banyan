import Foundation

/// Finds the next sibling boundary without changing a new session's parent.
public enum SessionSidebarCreationPolicy {
    public static func insertionBeforeID(
        in candidates: [SessionSidebarCandidate],
        groupID: String,
        parentSessionID: String?,
        focusedSessionID: String?,
        sortMode: SortMode
    ) -> String? {
        guard sortMode == .manual else { return nil }
        let group = candidates.filter { $0.groupID == groupID }
        let byID = Dictionary(group.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let parentID = parentSessionID.flatMap { byID[$0] == nil ? nil : $0 }
        var anchorID = SessionLaunchPolicy.preferredSessionID(for: focusedSessionID, in: group.map(\.id))
        var visited = Set<String>()
        while let id = anchorID, let anchor = byID[id], visited.insert(id).inserted {
            let anchorParentID = anchor.parentSessionID.flatMap { byID[$0] == nil ? nil : $0 }
            if anchorParentID == parentID {
                let rows = SessionSidebarHierarchyPolicy.rows(for: group.map {
                    SessionSelectionItem(id: $0.id, parentSessionID: $0.parentSessionID)
                })
                guard let index = rows.firstIndex(where: { $0.id == id }) else { return nil }
                // Skip the whole subtree, including children hidden by collapse.
                return rows.dropFirst(index + 1).first { $0.depth <= rows[index].depth }?.id
            }
            anchorID = anchorParentID
        }
        // No matching sibling (for example, a new child of the focused row):
        // append in storage, which places it last under its requested parent.
        return nil
    }
}
