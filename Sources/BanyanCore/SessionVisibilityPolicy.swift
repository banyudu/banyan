import Foundation

public struct SessionVisibilityItem: Sendable, Equatable {
    public let id: String
    public let status: SessionStatus
    public let updatedAt: Date
    public let displayTitle: String

    public init(
        id: String,
        status: SessionStatus,
        updatedAt: Date,
        displayTitle: String
    ) {
        self.id = id
        self.status = status
        self.updatedAt = updatedAt
        self.displayTitle = displayTitle
    }
}

/// Shared filtering and ordering rules for active session lists.
public enum SessionVisibilityPolicy {
    public static func visibleIDs(
        from items: [SessionVisibilityItem],
        sortMode: SortMode
    ) -> [String] {
        let active = items.filter { $0.status != .closed }
        switch sortMode {
        case .manual:
            return active.map(\.id)
        case .status:
            return active.sorted {
                if $0.status.priority == $1.status.priority {
                    return $0.updatedAt > $1.updatedAt
                }
                return $0.status.priority < $1.status.priority
            }.map(\.id)
        case .updated:
            return active.sorted { $0.updatedAt > $1.updatedAt }.map(\.id)
        case .title:
            return active.sorted {
                $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
            }.map(\.id)
        }
    }
}
