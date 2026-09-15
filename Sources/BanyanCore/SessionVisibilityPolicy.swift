import Foundation

public struct SessionVisibilityItem: Sendable, Equatable {
    public let id: String
    public let status: SessionStatus
    public let updatedAt: Date
    public let displayTitle: String
    public let isSuspended: Bool

    public init(
        id: String,
        status: SessionStatus,
        updatedAt: Date,
        displayTitle: String,
        isSuspended: Bool = false
    ) {
        self.id = id
        self.status = status
        self.updatedAt = updatedAt
        self.displayTitle = displayTitle
        self.isSuspended = isSuspended
    }
}

/// Shared filtering and ordering rules for active session lists.
public enum SessionVisibilityPolicy {
    public static func visibleIDs(
        from items: [SessionVisibilityItem],
        sortMode: SortMode
    ) -> [String] {
        let active = items.filter { $0.status != .closed }
        return sinkingSuspended(ordered(active, sortMode: sortMode)).map(\.id)
    }

    private static func ordered(
        _ items: [SessionVisibilityItem],
        sortMode: SortMode
    ) -> [SessionVisibilityItem] {
        switch sortMode {
        case .manual:
            return items
        case .status:
            return items.sorted {
                if $0.status.priority == $1.status.priority {
                    return $0.updatedAt > $1.updatedAt
                }
                return $0.status.priority < $1.status.priority
            }
        case .updated:
            return items.sorted { $0.updatedAt > $1.updatedAt }
        case .title:
            return items.sorted {
                $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
            }
        }
    }

    /// Parked sessions keep the order the sort mode gave them but sit below
    /// everything still being watched, including under a manual arrangement —
    /// the point of parking one is to stop it competing for attention.
    private static func sinkingSuspended(
        _ items: [SessionVisibilityItem]
    ) -> [SessionVisibilityItem] {
        items.filter { !$0.isSuspended } + items.filter(\.isSuspended)
    }
}
