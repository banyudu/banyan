import Foundation

/// Presentation order for daemon sessions outside Banyan's working set.
/// Summaries carry no timestamps, so the daemon's own order breaks ties.
public enum PuckBackgroundSessionPolicy {
    /// A pending approval or question blocks the agent until someone answers.
    @Sendable public static func hasPendingAsk(_ summary: PuckSessionSummary) -> Bool {
        summary.pendingApproval != nil || summary.pendingQuestion != nil
    }

    /// Asks first, then live turns, interruptions, results, and empty sessions.
    public static func ordered(_ summaries: [PuckSessionSummary]) -> [PuckSessionSummary] {
        summaries.enumerated().sorted { lhs, rhs in
            let left = rank(lhs.element), right = rank(rhs.element)
            return left != right ? left < right : lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func rank(_ summary: PuckSessionSummary) -> Int {
        if hasPendingAsk(summary) { return 0 }
        switch PuckSessionStatusPolicy.status(for: summary) {
        case .asking, .executing: return 1
        case .failed: return 2
        case .review: return 3
        default: return 4
        }
    }
}
