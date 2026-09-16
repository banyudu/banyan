import Foundation
import Testing
@testable import BanyanCore

private let paneSize = PaneSize(width: 120, height: 40)

@Test func inspectionCacheReusesTextWhenPaneProducedNoOutput() {
    let cache = SupervisorInspectionCache()
    let activity = Date(timeIntervalSince1970: 1_000)
    var captures = 0
    let read = {
        cache.read(paneID: "%1", lineLimit: 60, size: paneSize, lastActivityAt: activity) {
            captures += 1
            return PaneReading(text: "idle prompt")
        }.text
    }

    #expect(read() == "idle prompt")
    #expect(read() == "idle prompt")
    #expect(read() == "idle prompt")
    #expect(captures == 1)
}

@Test func inspectionCacheRecapturesAfterPaneActivity() {
    let cache = SupervisorInspectionCache()
    var captures = 0
    func read(activityAt: Date) -> String {
        cache.read(paneID: "%1", lineLimit: 60, size: paneSize, lastActivityAt: activityAt) {
            captures += 1
            return PaneReading(text: "capture \(captures)")
        }.text
    }

    #expect(read(activityAt: Date(timeIntervalSince1970: 1_000)) == "capture 1")
    #expect(read(activityAt: Date(timeIntervalSince1970: 1_001)) == "capture 2")
    #expect(captures == 2)
}

/// `#{window_activity}` only has whole-second resolution, so output landing later
/// in the same second as the capture would leave the timestamp unchanged. A
/// capture that does not trail its activity timestamp by a full second must
/// therefore never be reused.
@Test func inspectionCacheDoesNotReuseCaptureTakenInTheActivitySecond() {
    let cache = SupervisorInspectionCache()
    var captures = 0
    func read() -> String {
        cache.read(paneID: "%1", lineLimit: 60, size: paneSize, lastActivityAt: Date()) {
            captures += 1
            return PaneReading(text: "capture \(captures)")
        }.text
    }

    #expect(read() == "capture 1")
    #expect(read() == "capture 2")
}

/// A resize reflows a pane's text without the process writing anything, so the
/// activity timestamp alone cannot vouch for a capture taken at another size.
@Test func inspectionCacheRecapturesAfterPaneResize() {
    let cache = SupervisorInspectionCache()
    let activity = Date(timeIntervalSince1970: 1_000)
    var captures = 0
    func read(size: PaneSize) -> String {
        cache.read(paneID: "%1", lineLimit: 60, size: size, lastActivityAt: activity) {
            captures += 1
            return PaneReading(text: "capture \(captures)")
        }.text
    }

    #expect(read(size: paneSize) == "capture 1")
    #expect(read(size: paneSize) == "capture 1")
    #expect(read(size: PaneSize(width: 200, height: 40)) == "capture 2")
}

@Test func inspectionCacheAlwaysCapturesWithoutAnActivitySignal() {
    let cache = SupervisorInspectionCache()
    var captures = 0
    func read() -> String {
        cache.read(paneID: "%1", lineLimit: 60, size: paneSize, lastActivityAt: nil) {
            captures += 1
            return PaneReading(text: "capture \(captures)")
        }.text
    }

    #expect(read() == "capture 1")
    #expect(read() == "capture 2")
}

@Test func inspectionCacheKeepsEntriesForPanesThatSkipATick() {
    // Most sessions are deferred on any given tick — that is what the backoff is
    // for — so an entry must survive ticks its pane took no part in. Evicting on
    // "not inspected this time" would leave the cache never hitting.
    let cache = SupervisorInspectionCache()
    let activity = Date(timeIntervalSince1970: 1_000)
    var captures = 0
    func read(paneID: String) -> String {
        cache.read(paneID: paneID, lineLimit: 60, size: paneSize, lastActivityAt: activity) {
            captures += 1
            return PaneReading(text: "capture \(captures)")
        }.text
    }

    _ = read(paneID: "%1")
    for index in 2...20 {
        _ = read(paneID: "%\(index)")
    }
    _ = read(paneID: "%1")

    #expect(captures == 20)
}

@Test func inspectionCacheEvictsTheLeastRecentlyUsedPaneWhenFull() {
    // Nothing tells the cache a pane died — tmux hands out a fresh id for every
    // pane ever created — so the bound is what keeps a long-lived app from
    // holding a capture per pane it has ever seen.
    let cache = SupervisorInspectionCache()
    let activity = Date(timeIntervalSince1970: 1_000)
    var captures = 0
    func read(paneID: String) -> String {
        cache.read(paneID: paneID, lineLimit: 60, size: paneSize, lastActivityAt: activity) {
            captures += 1
            return PaneReading(text: "capture \(captures)")
        }.text
    }

    for index in 1...300 {
        _ = read(paneID: "%\(index)")
    }
    #expect(captures == 300)

    // The newest are still resident; the oldest have been dropped.
    _ = read(paneID: "%300")
    #expect(captures == 300)
    _ = read(paneID: "%1")
    #expect(captures == 301)
}

@Test func tmuxActivityTimestampParsesSecondsAndRejectsUnsetWindows() {
    #expect(TmuxBackend.activityDate("1789554348") == Date(timeIntervalSince1970: 1_789_554_348))
    #expect(TmuxBackend.activityDate("0") == nil)
    #expect(TmuxBackend.activityDate("") == nil)
    #expect(TmuxBackend.activityDate("#{window_activity}") == nil)
}

/// Scanning a capture costs more than taking it, so a reused capture must also
/// reuse what was concluded from it. A reading that is handed back from the
/// cache must therefore be the same object, with its conclusions intact.
@Test func inspectionCacheReusesTheConclusionsDrawnFromACapture() {
    let cache = SupervisorInspectionCache()
    let activity = Date(timeIntervalSince1970: 1_000)
    func read() -> PaneReading {
        cache.read(paneID: "%1", lineLimit: 60, size: paneSize, lastActivityAt: activity) {
            PaneReading(text: "esc to interrupt")
        }
    }

    let first = read()
    #expect(first.looksLikeAgentExecuting)
    #expect(read() === first)
}

@Test func paneReadingComputesEachConclusionOnce() {
    let reading = PaneReading(text: "Do you want to continue?")

    #expect(!reading.looksLikeAgentExecuting)
    #expect(reading.looksLikeAgentQuestion)
    #expect(reading.looksLikeAgentQuestion)
    #expect(reading.text == "Do you want to continue?")
}
