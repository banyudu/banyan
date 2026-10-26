import Foundation

public struct SessionSelectionItem: Sendable, Equatable {
    public let id: String
    public let parentSessionID: String?

    public init(id: String, parentSessionID: String?) {
        self.id = id
        self.parentSessionID = parentSessionID
    }
}

public struct SessionSelectionGroup: Sendable, Equatable {
    public let id: String
    public let items: [SessionSelectionItem]

    public init(id: String, items: [SessionSelectionItem]) {
        self.id = id
        self.items = items
    }
}

/// Chooses a nearby session after the selected session is removed.
public enum SessionClosingSelectionPolicy {
    public static func preferredIDAfterClosing(
        closingID: String,
        groups: [SessionSelectionGroup]
    ) -> String? {
        guard let groupIndex = groups.firstIndex(where: { group in
            group.items.contains { $0.id == closingID }
        }),
        let closingIndex = groups[groupIndex].items.firstIndex(where: { $0.id == closingID }) else {
            return nil
        }

        let group = groups[groupIndex]
        let groupIDs = Set(group.items.map(\.id))
        let closingItem = group.items[closingIndex]
        // Match the sidebar's effective hierarchy: a parent that is not part
        // of this group does not exist, so its children render as roots.
        func renderedParent(of item: SessionSelectionItem) -> String? {
            guard let parentID = item.parentSessionID, groupIDs.contains(parentID) else {
                return nil
            }
            return parentID
        }

        let closingParentID = renderedParent(of: closingItem)
        let siblings = group.items.enumerated().filter { index, item in
            renderedParent(of: item) == closingParentID
                && item.id != closingID
                && index != closingIndex
        }
        if let nextSibling = siblings.first(where: { $0.offset > closingIndex }) {
            return nextSibling.element.id
        }
        if let previousSibling = siblings.last(where: { $0.offset < closingIndex }) {
            return previousSibling.element.id
        }

        // A sub session with no remaining sibling stays in its own tree: fall
        // back to its parent instead of jumping to the next project group,
        // mirroring how closing the last session in a project stays local.
        if let parentID = closingParentID {
            return parentID
        }

        // Rows near the closing session may not share its raw parent. Closing
        // a parent promotes its children into its slot, and an orphaned row
        // renders as a top-level peer. Keep selection inside this project
        // whenever another row remains.
        if closingIndex + 1 < group.items.count {
            return group.items[closingIndex + 1].id
        }
        if closingIndex > 0 {
            return group.items[closingIndex - 1].id
        }

        if groupIndex + 1 < groups.count {
            return groups[groupIndex + 1].items.first?.id
        }
        if groupIndex > 0 {
            return groups[groupIndex - 1].items.last?.id
        }
        return nil
    }
}
