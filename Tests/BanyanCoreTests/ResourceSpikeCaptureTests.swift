import Foundation
import Testing
@testable import BanyanCore
#if os(macOS)
import Darwin
#endif

@Suite struct ResourceSpikeCaptureTests {
    private let active = ResourceCaptureContext(activity: "active", selectedSessionID: "session-1", startedSessionCount: 2)

    @Test func sustainedCPUAndSevereSpikeHaveDifferentTriggers() {
        var policy = ResourceSpikePolicy()
        let decision1 = !policy.shouldCapture(cpuPercent: 55, context: active, uptime: 0)
        #expect(decision1)
        let decision2 = !policy.shouldCapture(cpuPercent: 5, context: active, uptime: 5)
        #expect(decision2)
        let decision3 = !policy.shouldCapture(cpuPercent: 55, context: active, uptime: 10)
        #expect(decision3)
        let decision4 = policy.shouldCapture(cpuPercent: 55, context: active, uptime: 15)
        #expect(decision4)
        // Profiling failure still uses the same attempt/cooldown budget.
        let decision5 = !policy.shouldCapture(cpuPercent: 400, context: active, uptime: 20)
        #expect(decision5)
        let decision6 = policy.shouldCapture(cpuPercent: 100, context: active, uptime: 315)
        #expect(decision6)
    }

    @Test func hourlyBudgetBoundsRepeatedSpikes() {
        var policy = ResourceSpikePolicy()
        for index in 0..<6 {
            let decision7 = policy.shouldCapture(cpuPercent: 200, context: active, uptime: Double(index) * 300)
            #expect(decision7)
        }
        let decision8 = !policy.shouldCapture(cpuPercent: 200, context: active, uptime: 1800)
        #expect(decision8)
        let decision9 = !policy.shouldCapture(cpuPercent: 200, context: active, uptime: 3599)
        #expect(decision9)
        let decision10 = policy.shouldCapture(cpuPercent: 200, context: active, uptime: 3600)
        #expect(decision10)
    }

    @Test func restartRestoresCooldownAndHourBudget() {
        var policy = ResourceSpikePolicy()
        policy.restoreAttemptAges([30], uptime: 5000)
        let tooSoon = policy.shouldCapture(cpuPercent: 200, context: active, uptime: 5000)
        #expect(!tooSoon)
        let cooledDown = policy.shouldCapture(cpuPercent: 200, context: active, uptime: 5270)
        #expect(cooledDown)
        policy.restoreAttemptAges([600, 900, 1200, 1500, 1800, 2100], uptime: 6000)
        let overBudget = policy.shouldCapture(cpuPercent: 200, context: active, uptime: 6000)
        #expect(!overBudget)
    }

    @Test func hiddenCPUThresholdAndPowerCadence() {
        let hidden = ResourceCaptureContext(activity: "hidden")
        var policy = ResourceSpikePolicy()
        let decision11 = !policy.shouldCapture(cpuPercent: 25, context: hidden, uptime: 0)
        #expect(decision11)
        let decision12 = policy.shouldCapture(cpuPercent: 25, context: hidden, uptime: 10)
        #expect(decision12)
        #expect(active.samplingInterval == 5)
        #expect(hidden.samplingInterval == 10)
        var battery = active
        battery.isOnBattery = true
        #expect(battery.samplingInterval == 15)
        battery.isOnBattery = false
        battery.isLowPowerModeEnabled = true
        #expect(battery.samplingInterval == 15)
    }

    @Test func counterDeltasUseActualElapsedTimeAndRejectDiscontinuities() throws {
        let first = ProcessResourceSample(uptimeSeconds: 10, cpuSeconds: 2,
            interruptWakeups: 10, diskReadBytes: 100, cpuEnergyNanojoules: 1_000_000_000)
        let second = ProcessResourceSample(uptimeSeconds: 20, cpuSeconds: 7,
            interruptWakeups: 60, diskReadBytes: 300, cpuEnergyNanojoules: 3_000_000_000)
        let interval = try #require(second.interval(since: first, context: active))
        #expect(interval.cpuPercent == 50)
        #expect(interval.interruptWakeupsPerSecond == 5)
        #expect(interval.diskReadBytes == 200)
        #expect(interval.cpuEnergyJoules == 2)
        #expect(second.interval(since: second, context: active) == nil)
        #expect(first.interval(since: second, context: active) == nil)
        #expect(ProcessResourceSample(uptimeSeconds: 200, cpuSeconds: 8).interval(since: second, context: active) == nil)
        var policy = ResourceSpikePolicy()
        let decision13 = !policy.shouldCapture(cpuPercent: .nan, context: active, uptime: 0)
        #expect(decision13)
        let decision14 = !policy.shouldCapture(cpuPercent: .infinity, context: active, uptime: 1)
        #expect(decision14)
    }

    @Test func captureRetentionAndStackBoundIncludeIncompleteFiles() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var store = ResourceSpikeCaptureStore(directoryURL: directory)
        store.maxCaptures = 2
        store.maxStackBytes = 64
        let now = Date()
        let oldest = record(createdAt: now.addingTimeInterval(-20))
        try store.prepare(oldest)
        // An interrupted capture has no readable JSON but must still be pruned.
        try FileManager.default.removeItem(at: store.captureDirectory(id: oldest.id).appendingPathComponent("capture.json"))
        // Retention orders directory mtimes, not JSON dates. Set distinct ages
        // after mutations, including deletion of the incomplete capture's JSON.
        try FileManager.default.setAttributes([.modificationDate: oldest.createdAt],
            ofItemAtPath: store.captureDirectory(id: oldest.id).path)
        let next = record(createdAt: now.addingTimeInterval(-10))
        try store.prepare(next)
        try FileManager.default.setAttributes([.modificationDate: next.createdAt],
            ofItemAtPath: store.captureDirectory(id: next.id).path)
        let newest = record(createdAt: now)
        try store.prepare(newest)
        try FileManager.default.setAttributes([.modificationDate: newest.createdAt],
            ofItemAtPath: store.captureDirectory(id: newest.id).path)
        #expect(!FileManager.default.fileExists(atPath: store.captureDirectory(id: oldest.id).path))
        let raw = store.captureDirectory(id: newest.id).appendingPathComponent("sample.partial")
        try Data(repeating: 65, count: 200).write(to: raw)
        #expect(try store.finishStack(id: newest.id, temporaryURL: raw))
        let stack = store.captureDirectory(id: newest.id).appendingPathComponent("stack.txt")
        #expect(try Data(contentsOf: stack).count == 64)
        #expect(!FileManager.default.fileExists(atPath: raw.path))
        #expect(store.records(since: .distantPast).count == 2)
        #expect(store.records(since: newest.createdAt.addingTimeInterval(1)).isEmpty)
        try store.prune(now: Date().addingTimeInterval(15 * 86400))
        #expect(store.records(since: .distantPast).isEmpty)
    }

    #if os(macOS)
    @Test func liveKernelCPUTimeMatchesGetrusageUnits() throws {
        var usage = rusage()
        #expect(getrusage(RUSAGE_SELF, &usage) == 0)
        let sample = try #require(ResourceSpikeMonitor.readCounters(pid: getpid()))
        let seconds = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        // These are cumulative, adjacent reads of the same live process. This
        // catches using nanoseconds instead of Mach ticks on Apple silicon.
        #expect(abs(sample.cpuSeconds - seconds) < 0.5)
        #expect(sample.footprintBytes > 0)
    }

    @Test func realStackCaptureProducesMetadataAndLocalPerformanceEvent() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ResourceSpikeCaptureStore(directoryURL: directory.appendingPathComponent("captures"))
        let database = PerformanceEventStore(databaseURL: directory.appendingPathComponent("state.sqlite"))
        let telemetry = PerformanceTelemetry(store: database)
        let monitor = ResourceSpikeMonitor(store: store, telemetry: telemetry,
            environment: ProcessInfo.processInfo.environment, appVersion: "test", build: "test")
        let initial = record(createdAt: Date(), processID: getpid())
        // Samples this test process, not the user's running Banyan or an agent.
        monitor.capture(initial)
        telemetry.flushPendingEventsAndWait()
        let saved = try #require(store.records(since: .distantPast).first)
        #expect(saved.status == "complete")
        #expect(saved.error == nil)
        #expect(saved.stackFile == "stack.txt")
        #expect(saved.trigger.context.selectedSessionID == "session-1")
        let text = try String(contentsOf: store.captureDirectory(id: saved.id).appendingPathComponent("stack.txt"), encoding: .utf8)
        #expect(text.contains("Call graph:"))
        let event = try #require(database.loadEvents(since: .distantPast).first)
        #expect(event.name == "resource.cpu_spike")
        #expect(event.correlationID == saved.id)
        #expect(event.detail?.contains("status=complete") == true)
    }
    @Test func failedSamplerLeavesReadableFailureMetadata() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ResourceSpikeCaptureStore(directoryURL: directory.appendingPathComponent("captures"))
        let telemetry = PerformanceTelemetry(store: PerformanceEventStore(databaseURL: directory.appendingPathComponent("state.sqlite")))
        let monitor = ResourceSpikeMonitor(store: store, telemetry: telemetry,
            environment: ProcessInfo.processInfo.environment, appVersion: "test", build: "test")
        monitor.capture(record(createdAt: Date(), processID: .max))
        let saved = try #require(store.records(since: .distantPast).first)
        #expect(saved.status == "failed")
        #expect(saved.error != nil)
        #expect(saved.stackFile == nil)
        #expect(!FileManager.default.fileExists(atPath: store.captureDirectory(id: saved.id).appendingPathComponent("sample.partial").path))
    }
    #endif

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("banyan-cpu-capture-test-\(UUID().uuidString)")
    }

    private func record(createdAt: Date, processID: Int32 = 1) -> ResourceSpikeCaptureRecord {
        let interval = ResourceUsageInterval(timestamp: createdAt, elapsedSeconds: 5, cpuPercent: 100,
            interruptWakeupsPerSecond: 50, diskReadBytes: 100, diskWriteBytes: 20,
            footprintBytes: 1000, cpuEnergyJoules: nil, context: active)
        return ResourceSpikeCaptureRecord(id: UUID().uuidString, createdAt: createdAt,
            processID: processID, appVersion: "test", build: "test", processUptimeSeconds: 60,
            trigger: interval, recentSamples: [interval], status: "capturing", error: nil,
            stackFile: nil, stackTruncated: false)
    }
}
