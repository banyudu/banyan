import Foundation

/// Which closed sessions have aged out of `state.sqlite`.
///
/// `sessions` had no retention at all while `performance_events` has had one
/// since it was written, so years of dead worktrees stayed on the restore path
/// forever. The cost is not the row count itself: the launch path resolves git
/// context once per *distinct* `cwd`, on the main thread, so history nobody will
/// reopen is what a cold start actually spends its minutes on.
///
/// The rule is deliberately conservative. Deleting a session row is not
/// reversible, so a row goes only when it is closed, older than the window, not
/// the selected session, and not holding up a row that survives.
public enum SessionRetentionPolicy {
    /// A month is long enough to reopen last week's work and short enough to
    /// keep the restore pass proportional to the sessions a user actually has.
    public static let defaultRetentionDays = 30

    /// Offered in Preferences, in order. `0` is "Never", i.e. keep everything —
    /// the escape hatch for anyone who treats the sidebar as an archive.
    public static let retentionDayChoices = [7, 14, 30, 90, 180, 0]

    /// The four columns the policy needs, rather than a whole `SessionSnapshot`.
    /// The prune runs *before* snapshots are built, and reading only this much
    /// is what keeps it that way.
    public struct Row: Sendable, Equatable {
        public let id: String
        public let parentSessionID: String?
        public let status: SessionStatus
        public let updatedAt: Date

        public init(
            id: String,
            parentSessionID: String? = nil,
            status: SessionStatus,
            updatedAt: Date
        ) {
            self.id = id
            self.parentSessionID = parentSessionID
            self.status = status
            self.updatedAt = updatedAt
        }
    }

    /// A negative window is the same promise as "never": keep everything.
    public static func normalizedRetentionDays(_ days: Int) -> Int { max(0, days) }

    /// `nil` when retention is off, so a caller can tell "keep everything" from
    /// "keep nothing". Collapsing both to a cutoff would make a disabled setting
    /// delete the entire table.
    public static func cutoff(retentionDays: Int, now: Date = Date()) -> Date? {
        let days = normalizedRetentionDays(retentionDays)
        guard days > 0 else { return nil }
        return now.addingTimeInterval(-Double(days) * 24 * 60 * 60)
    }

    public static func label(retentionDays: Int) -> String {
        switch normalizedRetentionDays(retentionDays) {
        case 0: return "Never"
        case 1: return "1 day"
        case let days: return "\(days) days"
        }
    }

    /// Parses a `--older-than` argument: a bare day count, or one carrying the
    /// `d` suffix the rest of the CLI's durations use. `nil` is a rejection, not
    /// a fallback — silently pruning with a window the user did not ask for is
    /// the one mistake this command cannot take back.
    public static func retentionDays(fromDurationArgument value: String) -> Int? {
        var text = value.trimmingCharacters(in: .whitespaces).lowercased()
        if text.hasSuffix("d") { text.removeLast() }
        guard let days = Int(text), days >= 0 else { return nil }
        return days
    }

    /// The IDs safe to delete, in the order they were given.
    ///
    /// A row survives when it is not closed, is the selected session, is newer
    /// than the cutoff, or is an ancestor of a row that survives for one of
    /// those reasons. The ancestor walk is transitive on purpose: a closed,
    /// aged-out grandparent whose child is equally closed and aged out still has
    /// to stay when a live grandchild hangs off that child, or the sidebar loses
    /// the chain that explains where the grandchild came from.
    public static func expiredSessionIDs(
        rows: [Row],
        cutoff: Date?,
        selectedSessionID: String? = nil
    ) -> [String] {
        guard let cutoff else { return [] }
        let rowsByID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        var retained: Set<String> = []
        var pending: [Row] = []
        for row in rows where !isExpired(row, cutoff: cutoff, selectedSessionID: selectedSessionID) {
            if retained.insert(row.id).inserted {
                pending.append(row)
            }
        }
        while let row = pending.popLast() {
            guard let parentID = row.parentSessionID,
                  let parent = rowsByID[parentID],
                  // Also what terminates the walk if two rows ever name each
                  // other as parent.
                  retained.insert(parentID).inserted else { continue }
            pending.append(parent)
        }
        return rows.map(\.id).filter { !retained.contains($0) }
    }

    private static func isExpired(_ row: Row, cutoff: Date, selectedSessionID: String?) -> Bool {
        row.status == .closed && row.updatedAt < cutoff && row.id != selectedSessionID
    }
}
