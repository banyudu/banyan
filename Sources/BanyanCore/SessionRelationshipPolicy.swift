import Foundation

public struct SessionRelationshipItem: Sendable, Equatable {
    public let id: String
    public let parentSessionID: String?
    public let status: SessionStatus
    public let isImportedHistory: Bool
    public let isSuspended: Bool
    public let projectGroupID: String

    public init(
        id: String,
        parentSessionID: String?,
        status: SessionStatus,
        isImportedHistory: Bool = false,
        isSuspended: Bool = false,
        projectGroupID: String = ""
    ) {
        self.id = id
        self.parentSessionID = parentSessionID
        self.status = status
        self.isImportedHistory = isImportedHistory
        self.isSuspended = isSuspended
        self.projectGroupID = projectGroupID
    }
}

/// Shared parent/child relationship rules for live sessions.
public enum SessionRelationshipPolicy {
    /// Validates the complete move before a caller changes any live or persisted state.
    /// Only the source's parent link changes; its descendants and manual order stay put.
    public static func validatedParentID(
        for sourceID: String,
        proposedParentID: String?,
        in items: [SessionRelationshipItem]
    ) throws -> String? {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return try validatedParentID(for: sourceID, proposedParentID: proposedParentID, byID: byID)
    }

    /// Reuses one index when a target picker validates the active hierarchy.
    public static func validParentIDs(for sourceID: String, in items: [SessionRelationshipItem]) -> Set<String> {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return Set(items.compactMap {
            try? validatedParentID(for: sourceID, proposedParentID: $0.id, byID: byID)
        })
    }

    private static func validatedParentID(
        for sourceID: String,
        proposedParentID: String?,
        byID: [String: SessionRelationshipItem]
    ) throws -> String? {
        guard let source = byID[sourceID] else { throw SessionReparentingError.sourceNotFound(sourceID) }
        guard source.status != .closed, !source.isImportedHistory else {
            throw SessionReparentingError.inactiveSource(sourceID)
        }
        guard let parentID = SessionInputPolicy.normalizedOptionalText(proposedParentID) else { return nil }
        guard parentID != sourceID else { throw SessionReparentingError.selfParent }
        guard let parent = byID[parentID] else { throw SessionReparentingError.parentNotFound(parentID) }
        guard parent.status != .closed, !parent.isImportedHistory else {
            throw SessionReparentingError.inactiveParent(parentID)
        }
        guard source.projectGroupID == parent.projectGroupID else {
            throw SessionReparentingError.differentProjectGroup
        }
        var visited: Set<String> = [sourceID]
        var cursor: String? = parentID
        while let id = cursor {
            guard visited.insert(id).inserted else { throw SessionReparentingError.cycle }
            cursor = byID[id]?.parentSessionID
        }
        return parentID
    }

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

public enum SessionReparentingError: LocalizedError, Equatable {
    case sourceNotFound(String)
    case inactiveSource(String)
    case parentNotFound(String)
    case inactiveParent(String)
    case selfParent
    case cycle
    case differentProjectGroup

    public var errorDescription: String? {
        switch self {
        case .sourceNotFound(let id): return "No source session found for id '\(id)'"
        case .inactiveSource(let id): return "Source session '\(id)' is closed or imported history; only active sessions can be moved"
        case .parentNotFound(let id): return "No parent session found for id '\(id)'"
        case .inactiveParent(let id): return "Parent session '\(id)' is closed or imported history; an active parent is required"
        case .selfParent: return "A session cannot be its own parent"
        case .cycle: return "Cannot move a session under its descendant or into a cycle"
        case .differentProjectGroup: return "Source and parent must be in the same project sidebar group"
        }
    }
}
