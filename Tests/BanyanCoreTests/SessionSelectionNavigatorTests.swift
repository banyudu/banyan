import BanyanCore
import Testing

@Test func adjacentSelectionWrapsForwardAndBackward() {
    let ids = ["one", "two", "three"]

    #expect(SessionSelectionNavigator.adjacentID(in: ids, selectedID: "one", direction: .next) == "two")
    #expect(SessionSelectionNavigator.adjacentID(in: ids, selectedID: "three", direction: .next) == "one")
    #expect(SessionSelectionNavigator.adjacentID(in: ids, selectedID: "three", direction: .previous) == "two")
    #expect(SessionSelectionNavigator.adjacentID(in: ids, selectedID: "one", direction: .previous) == "three")
}

@Test func adjacentSelectionFallsBackWhenCurrentSelectionIsMissing() {
    let ids = ["one", "two", "three"]

    #expect(SessionSelectionNavigator.adjacentID(in: ids, selectedID: nil, direction: .next) == "one")
    #expect(SessionSelectionNavigator.adjacentID(in: ids, selectedID: "missing", direction: .next) == "one")
    #expect(SessionSelectionNavigator.adjacentID(in: ids, selectedID: nil, direction: .previous) == "three")
    #expect(SessionSelectionNavigator.adjacentID(in: ids, selectedID: "missing", direction: .previous) == "three")
}

@Test func adjacentSelectionReturnsNilForEmptySessionList() {
    #expect(SessionSelectionNavigator.adjacentID(in: [], selectedID: "one", direction: .next) == nil)
    #expect(SessionSelectionNavigator.adjacentID(in: [], selectedID: "one", direction: .previous) == nil)
}

@Test func directSelectionUsesOneBasedIndexes() {
    let ids = ["one", "two", "three"]

    #expect(SessionSelectionNavigator.directID(in: ids, oneBasedIndex: 1) == "one")
    #expect(SessionSelectionNavigator.directID(in: ids, oneBasedIndex: 3) == "three")
    #expect(SessionSelectionNavigator.directID(in: ids, oneBasedIndex: 0) == nil)
    #expect(SessionSelectionNavigator.directID(in: ids, oneBasedIndex: 4) == nil)
}

@Test func nextMatchingSelectionCyclesThroughMatches() {
    let ids = ["one", "two", "three", "four"]
    let matches: Set<String> = ["two", "four"]

    #expect(SessionSelectionNavigator.nextMatchingID(in: ids, selectedID: nil, isMatch: matches.contains) == "two")
    #expect(SessionSelectionNavigator.nextMatchingID(in: ids, selectedID: "one", isMatch: matches.contains) == "two")
    #expect(SessionSelectionNavigator.nextMatchingID(in: ids, selectedID: "two", isMatch: matches.contains) == "four")
    #expect(SessionSelectionNavigator.nextMatchingID(in: ids, selectedID: "four", isMatch: matches.contains) == "two")
}

@Test func nextMatchingSelectionReturnsNilWithoutMatches() {
    #expect(SessionSelectionNavigator.nextMatchingID(in: ["one", "two"], selectedID: "one") { _ in false } == nil)
}

@Test func matchingSelectionWrapsBackwardThroughMatches() {
    let ids = ["one", "two", "three", "four"]
    let matches: Set<String> = ["two", "four"]

    #expect(navigatePrevious(ids, from: "three", matches) == "two")
    #expect(navigatePrevious(ids, from: "two", matches) == "four")
    #expect(navigatePrevious(ids, from: "one", matches) == "four")
    #expect(navigatePrevious(ids, from: nil, matches) == "four")
}

@Test func matchingSelectionCanSkipTheCurrentSelection() {
    let ids = ["one", "two", "three"]
    let onlyMatch: Set<String> = ["two"]

    // Sitting on the single match: including it silently reselects, excluding it
    // makes "nothing else is waiting" an observable no-op.
    #expect(SessionSelectionNavigator.matchingID(
        in: ids,
        selectedID: "two",
        direction: .next,
        isMatch: onlyMatch.contains
    ) == "two")
    #expect(SessionSelectionNavigator.matchingID(
        in: ids,
        selectedID: "two",
        direction: .next,
        includingSelection: false,
        isMatch: onlyMatch.contains
    ) == nil)
    #expect(SessionSelectionNavigator.matchingID(
        in: ids,
        selectedID: "two",
        direction: .previous,
        includingSelection: false,
        isMatch: onlyMatch.contains
    ) == nil)
}

@Test func matchingSelectionStillMovesOffTheSelectionWhenOthersMatch() {
    let ids = ["one", "two", "three", "four"]
    let matches: Set<String> = ["two", "four"]

    #expect(SessionSelectionNavigator.matchingID(
        in: ids,
        selectedID: "two",
        direction: .next,
        includingSelection: false,
        isMatch: matches.contains
    ) == "four")
    #expect(SessionSelectionNavigator.matchingID(
        in: ids,
        selectedID: "four",
        direction: .next,
        includingSelection: false,
        isMatch: matches.contains
    ) == "two")
    #expect(SessionSelectionNavigator.matchingID(
        in: ids,
        selectedID: "two",
        direction: .previous,
        includingSelection: false,
        isMatch: matches.contains
    ) == "four")
}

@Test func matchingSelectionFallsBackWhenSelectionIsMissing() {
    let ids = ["one", "two", "three"]
    let matches: Set<String> = ["two", "three"]

    #expect(navigatePrevious(ids, from: "missing", matches) == "three")
    #expect(SessionSelectionNavigator.matchingID(
        in: [],
        selectedID: nil,
        direction: .previous,
        isMatch: matches.contains
    ) == nil)
}

/// The composition the app actually runs: sidebar order + `needsAttention`.
private struct RosterEntry {
    let id: String
    let status: SessionStatus
    var isImportedHistory = false
    var isSuspended = false
}

// Parked sessions sink below the watched ones in the sidebar, so the roster
// ends with the two kinds attention navigation must walk past.
private let roster: [RosterEntry] = [
    RosterEntry(id: "running", status: .running),
    RosterEntry(id: "asking", status: .asking),
    RosterEntry(id: "idle", status: .idle),
    RosterEntry(id: "need-input", status: .needInput),
    RosterEntry(id: "executing", status: .executing),
    RosterEntry(id: "failed", status: .failed),
    RosterEntry(id: "imported-asking", status: .asking, isImportedHistory: true),
    RosterEntry(id: "parked-asking", status: .asking, isSuspended: true)
]

private func nextNeedingAttention(from selectedID: String?) -> String? {
    SessionSelectionNavigator.matchingID(
        in: roster.map(\.id),
        selectedID: selectedID,
        direction: .next,
        includingSelection: false,
        isMatch: needsAttention
    )
}

private func previousNeedingAttention(from selectedID: String?) -> String? {
    SessionSelectionNavigator.matchingID(
        in: roster.map(\.id),
        selectedID: selectedID,
        direction: .previous,
        includingSelection: false,
        isMatch: needsAttention
    )
}

private func needsAttention(_ id: String) -> Bool {
    guard let entry = roster.first(where: { $0.id == id }) else { return false }
    return SessionLifecyclePolicy.needsAttention(
        status: entry.status,
        isImportedHistory: entry.isImportedHistory,
        isSuspended: entry.isSuspended
    )
}

@Test func attentionNavigationSkipsBusyQuietAndImportedSessions() {
    #expect(nextNeedingAttention(from: "running") == "asking")
    #expect(nextNeedingAttention(from: "asking") == "need-input")
    #expect(nextNeedingAttention(from: "idle") == "need-input")
    #expect(nextNeedingAttention(from: "need-input") == "failed")
    #expect(nextNeedingAttention(from: "executing") == "failed")
}

@Test func attentionNavigationWrapsPastTheEndOfTheRoster() {
    // The roster ends with two sessions that are never targets, so the wrap has
    // to walk through both and keep going back to the top of the list.
    #expect(nextNeedingAttention(from: "failed") == "asking")
    #expect(nextNeedingAttention(from: "imported-asking") == "asking")
    #expect(nextNeedingAttention(from: "parked-asking") == "asking")
    #expect(previousNeedingAttention(from: "asking") == "failed")
    #expect(previousNeedingAttention(from: "running") == "failed")
}

@Test func attentionNavigationSkipsParkedSessions() {
    // Parking freezes the status, so "parked-asking" stays `.asking` forever and
    // would otherwise be a permanent stop on the way round.
    #expect(nextNeedingAttention(from: "failed") != "parked-asking")
    #expect(previousNeedingAttention(from: "running") != "parked-asking")
}

@Test func attentionNavigationReversesThroughTheSameSessions() {
    #expect(previousNeedingAttention(from: "failed") == "need-input")
    #expect(previousNeedingAttention(from: "executing") == "need-input")
    #expect(previousNeedingAttention(from: "need-input") == "asking")
    #expect(previousNeedingAttention(from: "idle") == "asking")
}

@Test func attentionNavigationStaysPutWhenNothingElseIsWaiting() {
    let calm = ["running", "asking", "idle"]
    let isMatch: (String) -> Bool = { $0 == "asking" }

    #expect(SessionSelectionNavigator.matchingID(
        in: calm,
        selectedID: "asking",
        direction: .next,
        includingSelection: false,
        isMatch: isMatch
    ) == nil)
    #expect(SessionSelectionNavigator.matchingID(
        in: calm,
        selectedID: "asking",
        direction: .previous,
        includingSelection: false,
        isMatch: isMatch
    ) == nil)
}

// Attention navigation targets a session blocked on a human, unless the
// actual question waits further down its subtree — then the chord skips the
// parent and lands where input is needed. A parent with nothing waiting below
// it stays a target.
private let hierarchyRoster: [SessionRelationshipItem] = [
    SessionRelationshipItem(id: "parent", parentSessionID: nil, status: .asking),
    SessionRelationshipItem(id: "child-need-input", parentSessionID: "parent", status: .needInput),
    SessionRelationshipItem(id: "child-failed", parentSessionID: "parent", status: .failed),
    SessionRelationshipItem(id: "solo", parentSessionID: nil, status: .asking),
    SessionRelationshipItem(id: "waiting-parent", parentSessionID: nil, status: .asking),
    SessionRelationshipItem(id: "busy-child", parentSessionID: "waiting-parent", status: .running),
    SessionRelationshipItem(id: "grandparent", parentSessionID: nil, status: .asking),
    SessionRelationshipItem(id: "middle", parentSessionID: "grandparent", status: .running),
    SessionRelationshipItem(id: "grandchild", parentSessionID: "middle", status: .needInput),
    SessionRelationshipItem(id: "parked-parent", parentSessionID: nil, status: .asking),
    SessionRelationshipItem(id: "parked-child", parentSessionID: "parked-parent", status: .asking, isSuspended: true),
    SessionRelationshipItem(id: "empty-parent", parentSessionID: nil, status: .asking),
    SessionRelationshipItem(id: "closed-child", parentSessionID: "empty-parent", status: .closed),
]

private func nextAttentionTarget(from selectedID: String?) -> String? {
    SessionSelectionNavigator.matchingID(
        in: hierarchyRoster.map(\.id),
        selectedID: selectedID,
        direction: .next,
        includingSelection: false,
        isMatch: isAttentionTarget
    )
}

private func previousAttentionTarget(from selectedID: String?) -> String? {
    SessionSelectionNavigator.matchingID(
        in: hierarchyRoster.map(\.id),
        selectedID: selectedID,
        direction: .previous,
        includingSelection: false,
        isMatch: isAttentionTarget
    )
}

private func isAttentionTarget(_ id: String) -> Bool {
    guard let entry = hierarchyRoster.first(where: { $0.id == id }) else { return false }
    guard SessionLifecyclePolicy.needsAttention(
        status: entry.status,
        isImportedHistory: entry.isImportedHistory,
        isSuspended: entry.isSuspended
    ) else {
        return false
    }
    return !SessionRelationshipPolicy.hasWaitingDescendant(of: id, in: hierarchyRoster) {
        SessionLifecyclePolicy.needsAttention(
            status: $0.status,
            isImportedHistory: $0.isImportedHistory,
            isSuspended: $0.isSuspended
        )
    }
}

@Test func attentionNavigationSkipsParentsWhileTheirSubtreeWaits() {
    // "parent" and "grandparent" need attention but are never targets while a
    // descendant waits; every other waiting session without a waiting
    // descendant is visited in sidebar order.
    #expect(nextAttentionTarget(from: "parent") == "child-need-input")
    #expect(nextAttentionTarget(from: "child-need-input") == "child-failed")
    #expect(nextAttentionTarget(from: "child-failed") == "solo")
    #expect(nextAttentionTarget(from: "solo") == "waiting-parent")
    #expect(nextAttentionTarget(from: "waiting-parent") == "grandchild")
    #expect(nextAttentionTarget(from: "grandparent") == "grandchild")
    #expect(nextAttentionTarget(from: "grandchild") == "parked-parent")
    #expect(nextAttentionTarget(from: "parked-parent") == "empty-parent")
    #expect(nextAttentionTarget(from: "empty-parent") == "child-need-input")
    #expect(previousAttentionTarget(from: "grandchild") == "waiting-parent")
    #expect(previousAttentionTarget(from: "waiting-parent") == "solo")
    #expect(previousAttentionTarget(from: "child-need-input") == "empty-parent")
}

@Test func attentionNavigationKeepsParentsWithNothingWaitingBelow() {
    // A waiting parent whose children are busy, parked, or closed stays a
    // stop: there is no deeper question to land on instead.
    #expect(isAttentionTarget("waiting-parent"))
    #expect(isAttentionTarget("parked-parent"))
    #expect(isAttentionTarget("empty-parent"))
    #expect(!isAttentionTarget("parent"))
    #expect(!isAttentionTarget("grandparent"))
}

private func navigatePrevious(
    _ ids: [String],
    from selectedID: String?,
    _ matches: Set<String>
) -> String? {
    SessionSelectionNavigator.matchingID(
        in: ids,
        selectedID: selectedID,
        direction: .previous,
        isMatch: matches.contains
    )
}
