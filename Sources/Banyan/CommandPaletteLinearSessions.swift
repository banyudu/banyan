import Foundation

/// An existing session that already tracks a Linear issue, offered by the
/// command palette when its query names that issue.
struct LinearIssueSessionMatch: Identifiable, Equatable {
    /// What opening the session does, which is what the row's title promises.
    enum State: Equatable {
        /// Running (or parked) now: switch to it.
        case live
        /// Closed in Banyan: reopen it and resume the agent session.
        case closed
        /// An agent transcript imported from disk: resume it as a new session.
        case importedHistory
    }

    let id: String
    let title: String
    let state: State
    let updatedAt: Date
}

/// Built-in palette rows for existing sessions on the issue named in the query.
///
/// These surface above the Open/Start quick actions, so pasting an issue ID
/// offers to continue the work that already exists instead of creating a
/// second session for the same issue.
enum LinearIssueSessionPaletteItems {
    static func items(
        issueID: String,
        matches: [LinearIssueSessionMatch],
        onOpen: @escaping (LinearIssueSessionMatch) -> Void
    ) -> [CommandPaletteItem] {
        matches.map { match in
            CommandPaletteItem(
                id: "linear.existing-session.\(match.id)",
                category: "Linear · Existing Session",
                title: title(for: match.state, issueID: issueID),
                detail: match.title,
                shortcut: "↩",
                priority: 1,
                action: { onOpen(match) }
            )
        }
    }

    static func title(for state: LinearIssueSessionMatch.State, issueID: String) -> String {
        switch state {
        case .live: return "Switch to Session for \(issueID)"
        case .closed: return "Reopen Session for \(issueID)"
        case .importedHistory: return "Resume Session for \(issueID)"
        }
    }
}
