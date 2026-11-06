import BanyanCore
import Foundation

/// The sidebar holds the user's Puck working set: sessions created in Banyan
/// or explicitly opened from a link, notification, the background list, or a
/// turn sent to them. Everything else `puckd` holds stays in the background.
/// Hiding a row is only presentation: the daemon keeps the session, its
/// transcript, and any running turn.
extension SessionStore {
    /// Rebuilds the background list from a daemon listing. A closed row counts
    /// as background too, so an ask on it is still discoverable.
    func updateBackgroundPuckSummaries(_ summaries: [PuckSessionSummary]) {
        lastPuckSummaries = summaries
        refreshBackgroundPuckSummaries()
    }

    /// Re-derives the background list after the working set changed, without
    /// waiting for the next listing.
    func refreshBackgroundPuckSummaries() {
        let workingSetIDs = Set(sessions.lazy.filter { $0.status != .closed }.map(\.id))
        let next = PuckBackgroundSessionPolicy.ordered(lastPuckSummaries.filter {
            !workingSetIDs.contains($0.id) && !pendingPuckCreationIDs.contains($0.id)
        })
        if next != backgroundPuckSummaries { backgroundPuckSummaries = next }
    }

    /// Records that the user chose this daemon session. It leaves the
    /// background list, and a restored row of unknown origin becomes theirs.
    func noteBackgroundPuckSessionOpened(_ id: String) {
        if legacyPuckSessionIDs.contains(id) { legacyPuckSessionIDs.remove(id) }
        refreshBackgroundPuckSummaries()
    }

    /// Ask events reach a working-set row as before. A session without a live
    /// row is notified from its latest summary, so hiding a row, or never
    /// opening it, does not hide a question that blocks its agent. Returns
    /// whether the event was a pending ask the user was told about.
    @discardableResult
    func routePuckWatchEvent(id: String, event: PuckSessionEvent) -> Bool {
        if let row = sessions.first(where: { $0.id == id && $0.status != .closed }) {
            guard let session = row as? PuckSession, !session.isSuspended else { return false }
            return attentionNotifier.notifyPuckAsk(session: session, event: event)
        }
        guard let summary = backgroundPuckSummaries.first(where: { $0.id == id }) else { return false }
        return attentionNotifier.notifyPuckAsk(summary: summary, title: backgroundPuckTitle(for: summary), event: event)
    }

    /// The name a background session goes by until it is opened: its project.
    func backgroundPuckTitle(for summary: PuckSessionSummary) -> String {
        PathDisplayName.make(path: summary.cwd, homeDirectory: homeDirectory)
    }

    /// The sidebar shows its background entry only when there is something
    /// behind it: a background session, or an earlier build's rows to review.
    var showsPuckBackgroundEntry: Bool {
        !backgroundPuckSummaries.isEmpty || !legacyPuckCleanupCandidates.isEmpty
    }

    var backgroundPuckAskCount: Int {
        backgroundPuckSummaries.lazy.filter(PuckBackgroundSessionPolicy.hasPendingAsk).count
    }

    // MARK: - Rows added by earlier builds

    /// Classifies restored Puck rows once. Rows restored before any
    /// classification came from builds that added every listed daemon session,
    /// so their origin is unknown; later rows were created or opened here.
    func classifyRestoredPuckRows() {
        let restoredIDs = Set(sessions.lazy.filter { $0 is PuckSession }.map(\.id))
        let stored = persistence.loadLegacyPuckSessionIDs()
        let next = stored.map { $0.intersection(restoredIDs) } ?? restoredIDs
        if next != legacyPuckSessionIDs {
            legacyPuckSessionIDs = next
        } else if stored == nil {
            // An empty first classification still has to be recorded, or a
            // later launch would classify this build's rows as unknown.
            persistence.saveLegacyPuckSessionIDs(next)
        }
    }

    /// Restored rows of unknown origin the user can remove together. Rows with
    /// evidence of deliberate use are kept without being offered: the
    /// selected row, one the user named, one in a session tree (only Banyan
    /// creates those), and one a workflow manages. Generic titles are not
    /// evidence either way, so the user chooses among the rest.
    var legacyPuckCleanupCandidates: [PuckSession] {
        guard !legacyPuckSessionIDs.isEmpty else { return [] }
        let parentIDs = Set(sessions.compactMap(\.parentSessionID))
        return sessions.compactMap { $0 as? PuckSession }.filter { session in
            legacyPuckSessionIDs.contains(session.id)
                && session.id != selectedSessionID
                && !session.isTitlePinned
                && session.parentSessionID == nil
                && !parentIDs.contains(session.id)
                && session.workflow == nil
        }
    }

    /// Removes the chosen rows of unknown origin from the sidebar and History.
    /// `remove` only drops Banyan's row: the daemon session, its transcript,
    /// and any running turn are untouched, and the session stays openable from
    /// the background list. Returns how many rows went.
    @discardableResult
    func removeLegacyPuckRows(ids: Set<String>) -> Int {
        let removable = Set(legacyPuckCleanupCandidates.map(\.id)).intersection(ids)
        var removed = 0
        for id in removable where (try? remove(id: id)) != nil {
            removed += 1
        }
        return removed
    }
}
