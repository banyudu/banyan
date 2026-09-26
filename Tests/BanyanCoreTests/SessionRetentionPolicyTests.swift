import Foundation
import Testing
@testable import BanyanCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let thirtyDays = SessionRetentionPolicy.cutoff(retentionDays: 30, now: now)!

private func row(
    _ id: String,
    status: SessionStatus = .closed,
    parent: String? = nil,
    ageDays: Double
) -> SessionRetentionPolicy.Row {
    SessionRetentionPolicy.Row(
        id: id,
        parentSessionID: parent,
        status: status,
        updatedAt: now.addingTimeInterval(-ageDays * 24 * 60 * 60)
    )
}

private func expired(
    _ rows: [SessionRetentionPolicy.Row],
    selectedSessionID: String? = nil
) -> [String] {
    SessionRetentionPolicy.expiredSessionIDs(
        rows: rows,
        cutoff: thirtyDays,
        selectedSessionID: selectedSessionID
    )
}

@Test func retentionCutoffIsExclusiveSoARowExactlyAtTheWindowSurvives() {
    let atCutoff = SessionRetentionPolicy.Row(
        id: "at-cutoff",
        parentSessionID: nil,
        status: .closed,
        updatedAt: thirtyDays
    )
    let justPast = SessionRetentionPolicy.Row(
        id: "just-past",
        parentSessionID: nil,
        status: .closed,
        updatedAt: thirtyDays.addingTimeInterval(-1)
    )

    #expect(expired([atCutoff, justPast]) == ["just-past"])
    // And the far side of the boundary: a row a second inside the window stays.
    #expect(expired([row("fresh", ageDays: 29.9), row("stale", ageDays: 30.1)]) == ["stale"])
}

@Test func retentionNeverRemovesASessionThatIsNotClosed() {
    // Every non-closed status, aged well past any window: a live agent's row is
    // not history, whatever its timestamp says.
    let live = SessionStatus.allCases
        .filter { $0 != .closed }
        .map { row("live-\($0.rawValue)", status: $0, ageDays: 400) }

    #expect(expired(live + [row("gone", ageDays: 400)]) == ["gone"])
}

@Test func retentionKeepsTheParentOfASessionThatSurvives() {
    // The parent is closed and aged out on its own terms, but dropping it would
    // orphan the running child that still points at it.
    let rows = [
        row("parent", ageDays: 400),
        row("child", status: .executing, parent: "parent", ageDays: 400),
        row("unrelated", ageDays: 400)
    ]

    #expect(expired(rows) == ["unrelated"])
}

@Test func retentionKeepsAWholeAncestorChainAboveASurvivingSession() {
    // Grandparent and parent are both closed and both past the window. Only the
    // grandchild is live — a single non-transitive pass would delete the
    // grandparent and cut the chain in half.
    let rows = [
        row("grandparent", ageDays: 400),
        row("parent", parent: "grandparent", ageDays: 400),
        row("grandchild", status: .needInput, parent: "parent", ageDays: 400)
    ]

    #expect(expired(rows).isEmpty)
}

@Test func retentionRemovesAWholeSubtreeWhenNothingInItSurvives() {
    let rows = [
        row("parent", ageDays: 400),
        row("child", parent: "parent", ageDays: 400),
        row("grandchild", parent: "child", ageDays: 400)
    ]

    #expect(expired(rows) == ["parent", "child", "grandchild"])
}

@Test func retentionNeverRemovesTheSelectedSession() {
    let rows = [row("selected", ageDays: 400), row("other", ageDays: 400)]

    #expect(expired(rows, selectedSessionID: "selected") == ["other"])
    // The guard reaches upward too: the selected row's ancestors stay with it.
    #expect(expired(
        [row("parent", ageDays: 400), row("selected", parent: "parent", ageDays: 400)],
        selectedSessionID: "selected"
    ).isEmpty)
}

@Test func retentionOffKeepsEverything() {
    let rows = [row("ancient", ageDays: 4000)]

    for days in [0, -1] {
        #expect(SessionRetentionPolicy.cutoff(retentionDays: days, now: now) == nil)
        #expect(SessionRetentionPolicy.expiredSessionIDs(
            rows: rows,
            cutoff: SessionRetentionPolicy.cutoff(retentionDays: days, now: now)
        ).isEmpty)
    }
}

@Test func retentionToleratesDanglingAndCircularParentLinks() {
    // Neither shape should exist, but a delete that cannot be undone is the
    // wrong place to find out: a missing parent is ignored, and a cycle
    // terminates instead of walking forever.
    let dangling = [row("orphan", parent: "never-existed", ageDays: 400)]
    #expect(expired(dangling) == ["orphan"])

    let cycle = [
        row("a", parent: "b", ageDays: 400),
        row("b", parent: "a", ageDays: 400),
        row("live", status: .running, parent: "a", ageDays: 400)
    ]
    #expect(expired(cycle).isEmpty)
}

@Test func retentionDefaultsToThirtyDaysAndOffersNeverAsAChoice() {
    #expect(SessionRetentionPolicy.defaultRetentionDays == 30)
    #expect(SessionRetentionPolicy.retentionDayChoices.contains(30))
    #expect(SessionRetentionPolicy.retentionDayChoices.contains(0))
    #expect(SessionRetentionPolicy.label(retentionDays: 0) == "Never")
    #expect(SessionRetentionPolicy.label(retentionDays: 1) == "1 day")
    #expect(SessionRetentionPolicy.label(retentionDays: 30) == "30 days")
    #expect(SessionRetentionPolicy.normalizedRetentionDays(-5) == 0)
}

@Test func retentionArgumentParsingRejectsAnythingItCannotReadAsDays() {
    #expect(SessionRetentionPolicy.retentionDays(fromDurationArgument: "30") == 30)
    #expect(SessionRetentionPolicy.retentionDays(fromDurationArgument: "30d") == 30)
    #expect(SessionRetentionPolicy.retentionDays(fromDurationArgument: " 7D ") == 7)
    #expect(SessionRetentionPolicy.retentionDays(fromDurationArgument: "0") == 0)
    // A silent fallback here would prune with a window nobody asked for.
    #expect(SessionRetentionPolicy.retentionDays(fromDurationArgument: "-1") == nil)
    #expect(SessionRetentionPolicy.retentionDays(fromDurationArgument: "12h") == nil)
    #expect(SessionRetentionPolicy.retentionDays(fromDurationArgument: "a month") == nil)
    #expect(SessionRetentionPolicy.retentionDays(fromDurationArgument: "") == nil)
}
