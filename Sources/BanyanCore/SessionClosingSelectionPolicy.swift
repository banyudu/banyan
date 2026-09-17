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
        let closingItem = group.items[closingIndex]
        let siblings = group.items.enumerated().filter { index, item in
            item.parentSessionID == closingItem.parentSessionID
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
        if let parentID = closingItem.parentSessionID {
            let parentExists = groups.contains { group in
                group.items.contains { $0.id == parentID }
            }
            if parentExists {
                return parentID
            }
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
