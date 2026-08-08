import Foundation
import Testing
@testable import BanyanCore

@Test func performanceStoreLoadsEventsAndSummarizesMetrics() {
    let store = PerformanceEventStore(databaseURL: temporaryDatabaseURL(), retentionDays: 30, maxEvents: 100)
    let now = Date()

    store.record(PerformanceEvent(
        name: "session_switch.total",
        sessionID: "one",
        correlationID: "switch-1",
        durationMS: 100,
        detail: "fast",
        createdAt: now.addingTimeInterval(-10)
    ))
    store.record(PerformanceEvent(
        name: "session_switch.total",
        sessionID: "two",
        correlationID: "switch-2",
        durationMS: 1_500,
        detail: "slow",
        createdAt: now.addingTimeInterval(-5)
    ))
    store.record(PerformanceEvent(
        name: "tmux.refresh_clients",
        sessionID: "two",
        correlationID: "switch-2",
        durationMS: 300,
        detail: nil,
        createdAt: now
    ))

    let report = store.report(since: now.addingTimeInterval(-60))
    let switchSummary = report.summaries.first { $0.name == "session_switch.total" }
    let tmuxSummary = report.summaries.first { $0.name == "tmux.refresh_clients" }

    #expect(report.eventCount == 3)
    #expect(switchSummary?.count == 2)
    #expect(switchSummary?.slowCount == 1)
    #expect(switchSummary?.maxMS == 1_500)
    #expect(tmuxSummary?.slowCount == 1)
    #expect(report.recentSlowEvents.map(\.name).contains("session_switch.total"))
}

@Test func performanceStoreFiltersBySinceDate() {
    let store = PerformanceEventStore(databaseURL: temporaryDatabaseURL(), retentionDays: 30, maxEvents: 100)
    let now = Date()
    store.record(PerformanceEvent(
        name: "session_switch.total",
        durationMS: 100,
        createdAt: now.addingTimeInterval(-120)
    ))
    store.record(PerformanceEvent(
        name: "session_switch.total",
        durationMS: 200,
        createdAt: now
    ))

    let events = store.loadEvents(since: now.addingTimeInterval(-60))

    #expect(events.count == 1)
    #expect(events.first?.durationMS == 200)
}

@Test func terminalDrawMetricRecordsCountAndPercentiles() {
    let store = PerformanceEventStore(databaseURL: temporaryDatabaseURL(), retentionDays: 30, maxEvents: 1_000)
    let now = Date()

    for i in 0..<10 {
        store.record(PerformanceEvent(
            name: "terminal.draw",
            durationMS: Double(5 + i),
            createdAt: now.addingTimeInterval(Double(-10 + i))
        ))
    }
    store.record(PerformanceEvent(
        name: "terminal.draw",
        durationMS: 25,
        createdAt: now
    ))

    let report = store.report(since: now.addingTimeInterval(-60))
    let drawSummary = report.summaries.first { $0.name == "terminal.draw" }

    #expect(drawSummary != nil)
    #expect(drawSummary?.count == 11)
    #expect(drawSummary?.thresholdMS == 16)
    #expect(drawSummary?.slowCount == 1)
    #expect(drawSummary?.maxMS == 25)
}

@Test func switchCapAcceptsRealSwitchesAndRejectsIdleSpans() {
    // Real switches (sub-cap) are recorded; idle/abandoned spans past the cap are
    // discarded so they can't inflate the switch-latency percentiles.
    #expect(PerformanceTelemetry.isWithinSwitchCap(41))
    #expect(PerformanceTelemetry.isWithinSwitchCap(2_030))
    #expect(PerformanceTelemetry.isWithinSwitchCap(PerformanceTelemetry.switchMeasurementCapMS))
    #expect(!PerformanceTelemetry.isWithinSwitchCap(30_749))
    #expect(!PerformanceTelemetry.isWithinSwitchCap(137_681))
}

@Test func performanceStoreEnforcesMaxEventsCapAcrossSessions() {
    // Prune no longer runs per insert, so the cap has to be enforced when the
    // write connection is opened — otherwise a table left over cap by a previous
    // run would stay that way until 500 more events arrived.
    let databaseURL = temporaryDatabaseURL()
    let now = Date()

    let unbounded = PerformanceEventStore(databaseURL: databaseURL, retentionDays: 30, maxEvents: 1_000)
    for index in 0..<50 {
        unbounded.record(PerformanceEvent(
            name: "terminal.draw",
            durationMS: Double(index),
            createdAt: now.addingTimeInterval(Double(index))
        ))
    }
    #expect(unbounded.loadEvents(since: now.addingTimeInterval(-60)).count == 50)

    let capped = PerformanceEventStore(databaseURL: databaseURL, retentionDays: 30, maxEvents: 10)
    capped.record(PerformanceEvent(
        name: "terminal.draw",
        durationMS: 999,
        createdAt: now.addingTimeInterval(100)
    ))

    // 10 newest survivors of the open-time prune, plus the event just recorded.
    let events = capped.loadEvents(since: now.addingTimeInterval(-60))
    #expect(events.count == 11)
    #expect(events.last?.durationMS == 999)
    // The oldest events were the ones dropped.
    #expect(events.first?.durationMS == 40)
}

@Test func performanceStoreStillRecordsAfterManyEvents() {
    // Crossing the amortised prune boundary must not lose the write connection
    // or stop recording.
    let store = PerformanceEventStore(databaseURL: temporaryDatabaseURL(), retentionDays: 30, maxEvents: 100)
    let now = Date()
    for index in 0..<600 {
        store.record(PerformanceEvent(
            name: "terminal.draw",
            durationMS: Double(index),
            createdAt: now.addingTimeInterval(Double(index))
        ))
    }

    let events = store.loadEvents(since: now.addingTimeInterval(-60))
    #expect(!events.isEmpty)
    #expect(events.count <= 600)
    #expect(events.last?.durationMS == 599)
}

private func temporaryDatabaseURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("BanyanCoreTests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("state.sqlite")
}
