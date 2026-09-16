import Foundation
import Testing
@testable import BanyanCore

@Test func eventLogReturnsOnlyTransitionsAfterTheClientsCursor() {
    var log = SessionEventLog()
    log.append(sessionID: "one", status: .executing, previousStatus: .idle)
    let second = log.append(sessionID: "one", status: .asking, previousStatus: .executing)
    let third = log.append(sessionID: "two", status: .needInput, previousStatus: .executing)

    let batch = log.batch(since: second.cursor - 1)

    #expect(batch.events.map(\.cursor) == [second.cursor, third.cursor])
    #expect(batch.events.map(\.sessionID) == ["one", "two"])
    #expect(batch.cursor == third.cursor)
    #expect(batch.truncated == false)
}

@Test func eventLogStartsAFreshClientFromNowRatherThanFromHistory() {
    // A bridge that just connected has no context for prompts answered an hour
    // ago; replaying them would make it re-announce every one.
    var log = SessionEventLog()
    log.append(sessionID: "one", status: .asking, previousStatus: .executing)

    let batch = log.batch(since: nil)

    #expect(batch.events.isEmpty)
    #expect(batch.cursor == log.cursor)
}

@Test func eventLogReportsTruncationWhenACursorHasAgedOut() {
    var log = SessionEventLog(capacity: 4)
    for index in 0..<10 {
        log.append(sessionID: "s\(index)", status: .asking, previousStatus: .executing)
    }

    let stale = log.batch(since: 1)
    let recent = log.batch(since: 8)

    // The client must learn it missed transitions so it re-syncs from /list
    // instead of assuming what it received is the whole story.
    #expect(stale.truncated == true)
    #expect(stale.events.count == 4)
    #expect(recent.truncated == false)
    #expect(recent.events.map(\.cursor) == [9, 10])
}

@Test func eventLogIsEmptyAndUntruncatedBeforeAnythingHappens() {
    let log = SessionEventLog()

    let batch = log.batch(since: 0)

    #expect(batch.events.isEmpty)
    #expect(batch.truncated == false)
    #expect(batch.cursor == 0)
}

@Test func eventLogHoldsTheCursorSteadyWhenNothingIsPending() {
    var log = SessionEventLog()
    let only = log.append(sessionID: "one", status: .asking, previousStatus: .executing)

    let batch = log.batch(since: only.cursor)

    #expect(batch.events.isEmpty)
    #expect(batch.cursor == only.cursor)
    #expect(batch.truncated == false)
}

@Test func eventCarriesWhatTheStatusChangedFrom() {
    var log = SessionEventLog()
    let event = log.append(sessionID: "one", status: .asking, previousStatus: .executing)

    #expect(event.previousStatus == .executing)
    #expect(event.status == .asking)
    #expect(event.sessionID == "one")
}
