import Foundation

public struct SessionRelationshipItem: Sendable, Equatable {
    public let id: String
    public let parentSessionID: String?
    public let status: SessionStatus
    public let isImportedHistory: Bool
    public let isSuspended: Bool

    public init(
        id: String,
        parentSessionID: String?,
        status: SessionStatus,
        isImportedHistory: Bool = false,
        isSuspended: Bool = false
    ) {
        self.id = id
        self.parentSessionID = parentSessionID
        self.status = status
        self.isImportedHistory = isImportedHistory
        self.isSuspended = isSuspended
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

    /// Whether any session nested under `parentID` at any depth satisfies
    /// `isWaiting`.
    ///
    /// Traversal follows parent links through every item, including closed
    /// ones, so a stale link can't hide a waiting descendant; what counts as
    /// waiting is up to the caller. Cycle-safe via a visited set.
    public static func hasWaitingDescendant(
        of parentID: String,
        in items: [SessionRelationshipItem],
        isWaiting: (SessionRelationshipItem) -> Bool
    ) -> Bool {
        var childrenByParent: [String: [SessionRelationshipItem]] = [:]
        for item in items {
            if let parent = item.parentSessionID {
                childrenByParent[parent, default: []].append(item)
            }
        }
        var visited: Set<String> = [parentID]
        var stack = childrenByParent[parentID] ?? []
        while let item = stack.popLast() {
            guard visited.insert(item.id).inserted else { continue }
            if isWaiting(item) { return true }
            stack.append(contentsOf: childrenByParent[item.id] ?? [])
        }
        return false
    }
}
