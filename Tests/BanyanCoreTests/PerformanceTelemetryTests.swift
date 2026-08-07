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

private func temporaryDatabaseURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("BanyanCoreTests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("state.sqlite")
}
