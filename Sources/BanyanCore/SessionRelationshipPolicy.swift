import Foundation

public struct SessionRelationshipItem: Sendable, Equatable {
    public let id: String
    public let parentSessionID: String?
    public let status: SessionStatus

    public init(id: String, parentSessionID: String?, status: SessionStatus) {
        self.id = id
        self.parentSessionID = parentSessionID
        self.status = status
    }
}

/// Shared parent/child relationship rules for live sessions.
public enum SessionRelationshipPolicy {
    public static func activeChildCount(
        of parentID: String,
        in items: [SessionRelationshipItem]
    ) -> Int {
        items.filter {
            $0.status != .closed && $0.parentSessionID == parentID
        }.count
    }

    public static func resolvedActiveParentID(
        _ proposedID: String?,
        activeSessionIDs: Set<String>
    ) -> String? {
        guard let normalizedID = SessionInputPolicy.normalizedOptionalText(proposedID),
              activeSessionIDs.contains(normalizedID) else {
            return nil
        }
        return normalizedID
    }
}
