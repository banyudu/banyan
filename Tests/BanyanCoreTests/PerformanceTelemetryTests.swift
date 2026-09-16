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

@Test func slowOnlyTelemetrySkipsFastSamples() {
    #expect(!PerformanceTelemetry.shouldRecordDuration("terminal.draw", durationMS: 15.9))
    #expect(PerformanceTelemetry.shouldRecordDuration("terminal.draw", durationMS: 16))
    #expect(!PerformanceTelemetry.shouldRecordDuration("supervisor.session", durationMS: 149.9))
    #expect(PerformanceTelemetry.shouldRecordDuration("supervisor.session", durationMS: 150))
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

@Test func batchedRecordWritesEveryEventInOneTransaction() {
    let store = PerformanceEventStore(databaseURL: temporaryDatabaseURL(), retentionDays: 30, maxEvents: 100)
    let now = Date()
    let batch = (0..<20).map { index in
        PerformanceEvent(
            name: "terminal.draw",
            durationMS: Double(index),
            createdAt: now.addingTimeInterval(Double(index))
        )
    }

    store.record(batch)

    let events = store.loadEvents(since: now.addingTimeInterval(-60))
    #expect(events.count == 20)
    #expect(events.first?.durationMS == 0)
    #expect(events.last?.durationMS == 19)
}

@Test func batchedRecordIgnoresEmptyBatches() {
    let store = PerformanceEventStore(databaseURL: temporaryDatabaseURL(), retentionDays: 30, maxEvents: 100)
    store.record([])
    #expect(store.loadEvents(since: Date().addingTimeInterval(-60)).isEmpty)
}

@Test func batchedRecordStillPrunesToMaxEvents() {
    // Prune is amortised over inserts, so a batch has to advance the counter by
    // its own size rather than by one.
    let store = PerformanceEventStore(databaseURL: temporaryDatabaseURL(), retentionDays: 30, maxEvents: 10)
    let now = Date()
    let batch = (0..<600).map { index in
        PerformanceEvent(
            name: "terminal.draw",
            durationMS: Double(index),
            createdAt: now.addingTimeInterval(Double(index))
        )
    }

    store.record(batch)
    // One more batch to cross the prune boundary.
    store.record([PerformanceEvent(name: "terminal.draw", durationMS: 999, createdAt: now.addingTimeInterval(1_000))])

    let events = store.loadEvents(since: now.addingTimeInterval(-60))
    #expect(events.count <= 11)
    #expect(events.last?.durationMS == 999)
}

@Test func samplerAlwaysKeepsSlowDrawsWithFullDetail() {
    var sampler = PerformanceSampler()
    // Every draw at or above the always-record bar survives, untagged.
    for _ in 0..<50 {
        #expect(sampler.decide(name: "terminal.draw", durationMS: 50) == .record(detailSuffix: nil))
        #expect(sampler.decide(name: "terminal.draw", durationMS: 412) == .record(detailSuffix: nil))
    }
}

@Test func samplerThinsRoutineDrawsToOneInN() {
    var sampler = PerformanceSampler()
    var kept = 0
    for _ in 0..<80 {
        if case .record = sampler.decide(name: "terminal.draw", durationMS: 18) {
            kept += 1
        }
    }
    #expect(kept == 10)
}

@Test func samplerTagsSurvivingSamplesWithTheirRate() {
    var sampler = PerformanceSampler()
    var decisions: [PerformanceSampler.Decision] = []
    for _ in 0..<8 {
        decisions.append(sampler.decide(name: "terminal.draw", durationMS: 20))
    }
    #expect(decisions.prefix(7).allSatisfy { $0 == .drop })
    #expect(decisions.last == .record(detailSuffix: "sample=1/8"))
}

@Test func samplerLeavesUnsampledMetricsUntouched() {
    // The AC metrics that are not high-frequency must keep every sample.
    var sampler = PerformanceSampler()
    for _ in 0..<40 {
        #expect(sampler.decide(name: "supervisor.tick", durationMS: 151) == .record(detailSuffix: nil))
        #expect(sampler.decide(name: "switcher.switch_visible", durationMS: 12) == .record(detailSuffix: nil))
        #expect(sampler.decide(name: "session_switch.total", durationMS: 40) == .record(detailSuffix: nil))
    }
}

@Test func samplerCountsEachMetricSeparately() {
    var sampler = PerformanceSampler(policies: [
        "a": .init(alwaysRecordAtOrAboveMS: 100, sampleRate: 2),
        "b": .init(alwaysRecordAtOrAboveMS: 100, sampleRate: 2)
    ])
    #expect(sampler.decide(name: "a", durationMS: 1) == .drop)
    #expect(sampler.decide(name: "b", durationMS: 1) == .drop)
    #expect(sampler.decide(name: "a", durationMS: 1) == .record(detailSuffix: "sample=1/2"))
    #expect(sampler.decide(name: "b", durationMS: 1) == .record(detailSuffix: "sample=1/2"))
}

@Test func telemetryBuffersEventsUntilFlush() {
    let databaseURL = temporaryDatabaseURL()
    let store = PerformanceEventStore(databaseURL: databaseURL, retentionDays: 30, maxEvents: 1_000)
    let telemetry = PerformanceTelemetry(store: store)
    let reader = PerformanceEventStore(databaseURL: databaseURL, retentionDays: 30, maxEvents: 1_000)
    let since = Date().addingTimeInterval(-60)

    for index in 0..<10 {
        telemetry.recordDuration("session_switch.total", durationMS: Double(index))
    }

    // Well under maxBufferedEvents and well inside flushInterval: still in memory.
    #expect(telemetry.bufferedEventCount == 10)
    #expect(reader.loadEvents(since: since).isEmpty)

    telemetry.flushPendingEventsAndWait()
    #expect(telemetry.bufferedEventCount == 0)
    #expect(reader.loadEvents(since: since).count == 10)
}

@Test func telemetryFlushesOnceTheBufferFills() {
    let databaseURL = temporaryDatabaseURL()
    let store = PerformanceEventStore(databaseURL: databaseURL, retentionDays: 30, maxEvents: 1_000)
    let telemetry = PerformanceTelemetry(store: store)
    let reader = PerformanceEventStore(databaseURL: databaseURL, retentionDays: 30, maxEvents: 1_000)
    let since = Date().addingTimeInterval(-60)

    let total = PerformanceTelemetry.maxBufferedEvents
    for index in 0..<(total - 1) {
        telemetry.recordDuration("session_switch.total", durationMS: Double(index))
    }
    #expect(telemetry.bufferedEventCount == total - 1)

    // The event that fills the buffer must write it out by itself. No explicit
    // flush, and the flush interval is far away, so an empty buffer backed by a
    // full table can only be the size trigger.
    telemetry.recordDuration("session_switch.total", durationMS: Double(total))
    #expect(telemetry.bufferedEventCount == 0)
    #expect(reader.loadEvents(since: since).count == total)
}

@Test func telemetrySamplesRoutineDrawsOnTheRecordingPath() {
    let databaseURL = temporaryDatabaseURL()
    let store = PerformanceEventStore(databaseURL: databaseURL, retentionDays: 30, maxEvents: 10_000)
    let telemetry = PerformanceTelemetry(store: store)
    let reader = PerformanceEventStore(databaseURL: databaseURL, retentionDays: 30, maxEvents: 10_000)
    let since = Date().addingTimeInterval(-60)

    // A streaming burst: 160 routine draws over the 16ms report threshold, plus
    // 5 genuinely slow ones.
    for _ in 0..<160 {
        telemetry.recordDurationIfSlow("terminal.draw", durationMS: 18)
    }
    for _ in 0..<5 {
        telemetry.recordDurationIfSlow("terminal.draw", durationMS: 300)
    }
    // Sub-threshold draws are dropped before they ever reach the buffer.
    for _ in 0..<500 {
        telemetry.recordDurationIfSlow("terminal.draw", durationMS: 4)
    }
    telemetry.flushPendingEventsAndWait()

    let events = reader.loadEvents(since: since)
    let slow = events.filter { $0.durationMS == 300 }
    let routine = events.filter { $0.durationMS == 18 }

    #expect(slow.count == 5)
    #expect(slow.allSatisfy { $0.detail == nil })
    #expect(routine.count == 20)
    #expect(routine.allSatisfy { $0.detail == "sample=1/8" })
    #expect(events.count == 25)
}

@Test func telemetryKeepsExistingDetailWhenTaggingASample() {
    let databaseURL = temporaryDatabaseURL()
    let store = PerformanceEventStore(databaseURL: databaseURL, retentionDays: 30, maxEvents: 1_000)
    let telemetry = PerformanceTelemetry(store: store)
    let reader = PerformanceEventStore(databaseURL: databaseURL, retentionDays: 30, maxEvents: 1_000)
    let since = Date().addingTimeInterval(-60)

    for _ in 0..<8 {
        telemetry.recordDurationIfSlow("terminal.draw", durationMS: 20, detail: "session=one")
    }
    telemetry.flushPendingEventsAndWait()

    let events = reader.loadEvents(since: since)
    #expect(events.count == 1)
    #expect(events.first?.detail == "session=one sample=1/8")
}

@Test func telemetryFlushOnAnEmptyBufferIsANoOp() {
    let databaseURL = temporaryDatabaseURL()
    let telemetry = PerformanceTelemetry(
        store: PerformanceEventStore(databaseURL: databaseURL, retentionDays: 30, maxEvents: 100)
    )
    telemetry.flushPendingEventsAndWait()
    telemetry.flushPendingEventsAndWait()

    let reader = PerformanceEventStore(databaseURL: databaseURL, retentionDays: 30, maxEvents: 100)
    #expect(reader.loadEvents(since: Date().addingTimeInterval(-60)).isEmpty)
}

@Test func formattedReportDisclosesSampledMetrics() {
    // `banyanctl perf report` and `perf prompt` both render this, and a sampled
    // count read as a true event rate would send an investigation the wrong way.
    let store = PerformanceEventStore(databaseURL: temporaryDatabaseURL(), retentionDays: 30, maxEvents: 100)
    let now = Date()
    store.record([
        PerformanceEvent(name: "terminal.draw", durationMS: 20, detail: "sample=1/8", createdAt: now),
        PerformanceEvent(name: "tmux.refresh_clients", durationMS: 300, createdAt: now)
    ])

    let text = store.formattedReport(since: now.addingTimeInterval(-60))

    #expect(text.contains("Sampled metrics:"))
    #expect(text.contains("terminal.draw: every event >= 50ms recorded, faster ones 1 in 8"))
    // Metrics that are never sampled must not appear in that section.
    #expect(!text.contains("tmux.refresh_clients: every event"))
}

@Test func formattedReportOmitsTheSamplingNoteWhenNoSampledMetricRan() {
    let store = PerformanceEventStore(databaseURL: temporaryDatabaseURL(), retentionDays: 30, maxEvents: 100)
    let now = Date()
    store.record(PerformanceEvent(name: "session_switch.total", durationMS: 40, createdAt: now))

    #expect(!store.formattedReport(since: now.addingTimeInterval(-60)).contains("Sampled metrics:"))
}

private func temporaryDatabaseURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("BanyanCoreTests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("state.sqlite")
}
