import Foundation

public struct SessionSidebarRow: Sendable, Equatable {
    public let id: String
    public let depth: Int

    public init(id: String, depth: Int) {
        self.id = id
        self.depth = depth
    }
}

/// Flattens a session parent/child tree into the order rendered by a sidebar.
public enum SessionSidebarHierarchyPolicy {
    public static func rows(for items: [SessionSelectionItem]) -> [SessionSidebarRow] {
        let activeIDs = Set(items.map(\.id))
        let grouped = Dictionary(grouping: items) { item in
            item.parentSessionID.flatMap { activeIDs.contains($0) ? $0 : nil }
        }
        var visited = Set<String>()
        var result: [SessionSidebarRow] = []

        func append(_ item: SessionSelectionItem, depth: Int) {
            guard !visited.contains(item.id) else { return }
            visited.insert(item.id)
            result.append(SessionSidebarRow(id: item.id, depth: depth))
            for child in grouped[item.id] ?? [] {
                append(child, depth: depth + 1)
            }
        }

        for root in grouped[nil] ?? [] {
            append(root, depth: 0)
        }
        for item in items where !visited.contains(item.id) {
            append(item, depth: 0)
        }
        return result
    }
}
