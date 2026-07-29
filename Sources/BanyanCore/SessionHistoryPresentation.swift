import Foundation

/// Shared formatting and filtering rules for history rows.
public enum SessionHistoryPresentation {
    /// Number of recent history rows shown without a search query.
    public static let sidebarBrowseLimit = 30

    /// Maximum history rows searched when a query is present.
    public static let sidebarSearchLimit = 100

    /// Imported transcript depth needed to resolve every row returned by the
    /// bounded history search.
    public static let recoveryImportLimit = sidebarSearchLimit

    public static func matchesFilter(title: String, query: String) -> Bool {
        let tokens = query.split(whereSeparator: \.isWhitespace)
        guard !tokens.isEmpty else { return true }
        return tokens.allSatisfy { token in
            title.range(of: token, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    public static func sidebarTitle(
        projectName: String,
        displayTitle: String,
        issueID: String?
    ) -> String {
        let title = displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let issueID, !issueID.isEmpty else {
            return "\(projectName) · \(title)"
        }
        let firstToken = title.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first
        if firstToken?.caseInsensitiveCompare(issueID) == .orderedSame {
            return title
        }
        return "\(issueID.uppercased()) · \(title)"
    }

    public static func staleTmuxSessionNames(
        liveSessionNames: [String],
        persistedSessionNames: Set<String>
    ) -> [String] {
        liveSessionNames
            .filter { !persistedSessionNames.contains($0) }
            .sorted()
    }
}
