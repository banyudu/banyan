import Foundation

/// A complete sidebar move: the new parent plus the manual order after the
/// source subtree has been moved as one unit.
public struct SessionSidebarMoveResult: Sendable, Equatable {
    public let parentSessionID: String?
    public let orderedIDs: [String]

    public init(parentSessionID: String?, orderedIDs: [String]) {
        self.parentSessionID = parentSessionID
        self.orderedIDs = orderedIDs
    }
}

/// Relative actions exposed by the sidebar. Drag destinations use the same
/// vocabulary as the context menu so both paths share one ordering policy.
public enum SessionSidebarMoveCommand: Sendable, Equatable {
    case up
    case down
    case indent
    case outdent
    case topLevel
    case before(String)
    case after(String)
    case child(String)
    case root
}

public struct SessionSidebarMoveOptions: OptionSet, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let up = Self(rawValue: 1 << 0)
    public static let down = Self(rawValue: 1 << 1)
    public static let indent = Self(rawValue: 1 << 2)
    public static let outdent = Self(rawValue: 1 << 3)
    public static let topLevel = Self(rawValue: 1 << 4)
    public static let all: Self = [.up, .down, .indent, .outdent, .topLevel]
}

/// Calculates sibling visibility and hierarchy-safe moves without mutating
/// session state. Callers still validate the resulting parent relationship
/// with `SessionRelationshipPolicy` before persisting it.
public enum SessionSidebarMovePolicy {
    public static func options(
        for sourceID: String,
        in items: [SessionSelectionItem]
    ) -> SessionSidebarMoveOptions {
        guard let hierarchy = Hierarchy(items: items) else { return [] }
        return options(for: sourceID, in: hierarchy)
    }

    private static func options(
        for sourceID: String,
        in hierarchy: Hierarchy
    ) -> SessionSidebarMoveOptions {
        guard hierarchy.contains(sourceID) else { return [] }
        let parentID = hierarchy.parent(of: sourceID)
        let siblings = hierarchy.siblings(of: parentID)
        guard let sourceIndex = siblings.firstIndex(of: sourceID) else { return [] }

        var options: SessionSidebarMoveOptions = []
        if sourceIndex > 0 {
            options.insert(.up)
            options.insert(.indent)
        }
        if sourceIndex + 1 < siblings.count {
            options.insert(.down)
        }
        if parentID != nil {
            options.insert(.outdent)
            options.insert(.topLevel)
        }
        return options
    }

    public static func optionsByID(
        in items: [SessionSelectionItem]
    ) -> [String: SessionSidebarMoveOptions] {
        guard let hierarchy = Hierarchy(items: items) else { return [:] }
        return Dictionary(uniqueKeysWithValues: hierarchy.ordered.map { item in
            (item.id, options(for: item.id, in: hierarchy))
        })
    }

    public static func move(
        sourceID: String,
        command: SessionSidebarMoveCommand,
        in items: [SessionSelectionItem]
    ) -> SessionSidebarMoveResult? {
        guard let hierarchy = Hierarchy(items: items),
              hierarchy.contains(sourceID) else {
            return nil
        }

        let sourceParentID = hierarchy.parent(of: sourceID)
        let siblings = hierarchy.siblings(of: sourceParentID)
        guard let sourceIndex = siblings.firstIndex(of: sourceID) else { return nil }

        let destinationParentID: String?
        let insertion: Insertion
        switch command {
        case .up:
            guard sourceIndex > 0 else { return nil }
            destinationParentID = sourceParentID
            insertion = .before(siblings[sourceIndex - 1])
        case .down:
            guard sourceIndex + 1 < siblings.count else { return nil }
            destinationParentID = sourceParentID
            insertion = .after(siblings[sourceIndex + 1])
        case .indent:
            guard sourceIndex > 0 else { return nil }
            destinationParentID = siblings[sourceIndex - 1]
            insertion = .last
        case .outdent:
            guard let sourceParentID else { return nil }
            destinationParentID = hierarchy.parent(of: sourceParentID)
            insertion = .after(sourceParentID)
        case .topLevel:
            guard sourceParentID != nil else { return nil }
            destinationParentID = nil
            insertion = .last
        case .before(let targetID):
            guard targetID != sourceID, hierarchy.contains(targetID) else { return nil }
            destinationParentID = hierarchy.parent(of: targetID)
            insertion = .before(targetID)
        case .after(let targetID):
            guard targetID != sourceID, hierarchy.contains(targetID) else { return nil }
            destinationParentID = hierarchy.parent(of: targetID)
            insertion = .after(targetID)
        case .child(let targetID):
            guard targetID != sourceID, hierarchy.contains(targetID) else { return nil }
            destinationParentID = targetID
            insertion = .last
        case .root:
            destinationParentID = nil
            insertion = .last
        }

        if let destinationParentID {
            guard hierarchy.contains(destinationParentID),
                  destinationParentID != sourceID,
                  !hierarchy.isDescendant(destinationParentID, of: sourceID) else {
                return nil
            }
        }

        var roots = hierarchy.roots
        var children = hierarchy.children
        remove(sourceID, from: &roots)
        for parentID in Array(children.keys) {
            var ids = children[parentID] ?? []
            remove(sourceID, from: &ids)
            children[parentID] = ids
        }

        let destinationIDs: [String]
        if let destinationParentID {
            destinationIDs = children[destinationParentID] ?? []
        } else {
            destinationIDs = roots
        }
        guard let insertionIndex = insertionIndex(
            for: insertion,
            in: destinationIDs
        ) else {
            return nil
        }

        if let destinationParentID {
            var updatedIDs = destinationIDs
            updatedIDs.insert(sourceID, at: insertionIndex)
            children[destinationParentID] = updatedIDs
        } else {
            roots.insert(sourceID, at: insertionIndex)
        }

        var visited = Set<String>()
        var orderedIDs: [String] = []
        orderedIDs.reserveCapacity(hierarchy.ordered.count)
        func append(_ id: String) {
            guard visited.insert(id).inserted else { return }
            orderedIDs.append(id)
            for childID in children[id] ?? [] {
                append(childID)
            }
        }
        for rootID in roots {
            append(rootID)
        }
        for item in hierarchy.ordered where !visited.contains(item.id) {
            append(item.id)
        }
        guard orderedIDs.count == hierarchy.ordered.count else { return nil }

        return SessionSidebarMoveResult(
            parentSessionID: destinationParentID,
            orderedIDs: orderedIDs
        )
    }

    private enum Insertion {
        case before(String)
        case after(String)
        case last
    }

    private static func insertionIndex(for insertion: Insertion, in ids: [String]) -> Int? {
        switch insertion {
        case .last:
            return ids.count
        case .before(let targetID):
            return ids.firstIndex(of: targetID)
        case .after(let targetID):
            guard let index = ids.firstIndex(of: targetID) else { return nil }
            return index + 1
        }
    }

    private static func remove(_ id: String, from ids: inout [String]) {
        ids.removeAll { $0 == id }
    }
}

private struct Hierarchy {
    let ordered: [SessionSelectionItem]
    let byID: [String: SessionSelectionItem]
    let roots: [String]
    let children: [String: [String]]

    init?(items: [SessionSelectionItem]) {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = SessionSidebarHierarchyPolicy.rows(for: items).compactMap { byID[$0.id] }
        guard ordered.count == byID.count else { return nil }

        var roots: [String] = []
        var children: [String: [String]] = [:]
        for item in ordered {
            if let parentID = item.parentSessionID, byID[parentID] != nil {
                children[parentID, default: []].append(item.id)
            } else {
                roots.append(item.id)
            }
        }
        self.ordered = ordered
        self.byID = byID
        self.roots = roots
        self.children = children
    }

    func contains(_ id: String) -> Bool {
        byID[id] != nil
    }

    func parent(of id: String) -> String? {
        guard let parentID = byID[id]?.parentSessionID,
              byID[parentID] != nil else {
            return nil
        }
        return parentID
    }

    func siblings(of parentID: String?) -> [String] {
        guard let parentID else { return roots }
        return children[parentID] ?? []
    }

    func isDescendant(_ candidateID: String, of ancestorID: String) -> Bool {
        var cursor = parent(of: candidateID)
        var visited = Set<String>()
        while let id = cursor, visited.insert(id).inserted {
            if id == ancestorID { return true }
            cursor = parent(of: id)
        }
        return false
    }
}
