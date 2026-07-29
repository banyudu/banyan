import Foundation

public struct SessionSidebarCandidate: Sendable, Equatable {
    public let id: String
    public let groupID: String
    public let groupTitle: String
    public let parentSessionID: String?

    public init(
        id: String,
        groupID: String,
        groupTitle: String,
        parentSessionID: String?
    ) {
        self.id = id
        self.groupID = groupID
        self.groupTitle = groupTitle
        self.parentSessionID = parentSessionID
    }
}

public struct SessionSidebarGroupRow: Sendable, Equatable {
    public let id: String
    public let title: String
    public let rows: [SessionSidebarRow]

    public init(id: String, title: String, rows: [SessionSidebarRow]) {
        self.id = id
        self.title = title
        self.rows = rows
    }
}

/// Groups visible sessions by project and orders the resulting sidebar groups.
public enum SessionSidebarGroupingPolicy {
    public static func groups(
        for candidates: [SessionSidebarCandidate]
    ) -> [SessionSidebarGroupRow] {
        var candidatesByGroup: [String: [SessionSidebarCandidate]] = [:]
        var orderedGroupIDs: [String] = []

        for candidate in candidates {
            if candidatesByGroup[candidate.groupID] == nil {
                orderedGroupIDs.append(candidate.groupID)
            }
            candidatesByGroup[candidate.groupID, default: []].append(candidate)
        }

        return orderedGroupIDs.compactMap { groupID in
            guard let groupCandidates = candidatesByGroup[groupID],
                  let first = groupCandidates.first else {
                return nil
            }
            let rows = SessionSidebarHierarchyPolicy.rows(for: groupCandidates.map {
                SessionSelectionItem(id: $0.id, parentSessionID: $0.parentSessionID)
            })
            return SessionSidebarGroupRow(id: groupID, title: first.groupTitle, rows: rows)
        }.sorted {
            let titleComparison = $0.title.localizedCaseInsensitiveCompare($1.title)
            if titleComparison == .orderedSame {
                return $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending
            }
            return titleComparison == .orderedAscending
        }
    }
}
