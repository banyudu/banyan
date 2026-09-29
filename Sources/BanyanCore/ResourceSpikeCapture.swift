import Foundation
#if os(macOS)
import Darwin
#endif

public struct ResourceCaptureContext: Codable, Equatable, Sendable {
    public var activity: String
    public var selectedSessionID: String?
    public var startedSessionCount: Int
    public var isOnBattery: Bool
    public var isLowPowerModeEnabled: Bool

    public init(activity: String = "hidden", selectedSessionID: String? = nil,
                startedSessionCount: Int = 0, isOnBattery: Bool = false,
                isLowPowerModeEnabled: Bool = false) {
        self.activity = activity
        self.selectedSessionID = selectedSessionID
        self.startedSessionCount = startedSessionCount
        self.isOnBattery = isOnBattery
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
    }

    /// There is no process-CPU notification. One cheap kernel read is necessary
    /// to catch spontaneous spikes, including when the main thread is blocked.
    public var samplingInterval: TimeInterval {
        let base: Double = activity == "active" && startedSessionCount > 0 ? 5 : 10
        return isOnBattery || isLowPowerModeEnabled ? max(15, base) : base
    }
}

/// Counters for the app process only, excluding tmux, agents and the sampler.
public struct ProcessResourceSample: Sendable {
    public let timestamp: Date
    public let uptimeSeconds: Double
    public let cpuSeconds: Double
    public let interruptWakeups: UInt64
    public let diskReadBytes: UInt64
    public let diskWriteBytes: UInt64
    public let footprintBytes: UInt64
    public let cpuEnergyNanojoules: UInt64?
    public let processStartUptimeSeconds: Double?

    public init(timestamp: Date = Date(), uptimeSeconds: Double, cpuSeconds: Double,
                interruptWakeups: UInt64 = 0, diskReadBytes: UInt64 = 0,
                diskWriteBytes: UInt64 = 0, footprintBytes: UInt64 = 0,
                cpuEnergyNanojoules: UInt64? = nil, processStartUptimeSeconds: Double? = nil) {
        self.timestamp = timestamp
        self.uptimeSeconds = uptimeSeconds
        self.cpuSeconds = cpuSeconds
        self.interruptWakeups = interruptWakeups
        self.diskReadBytes = diskReadBytes
        self.diskWriteBytes = diskWriteBytes
        self.footprintBytes = footprintBytes
        self.cpuEnergyNanojoules = cpuEnergyNanojoules
        self.processStartUptimeSeconds = processStartUptimeSeconds
    }

    public func interval(since previous: Self, context: ResourceCaptureContext) -> ResourceUsageInterval? {
        let elapsed = uptimeSeconds - previous.uptimeSeconds
        guard elapsed > 0, elapsed <= 120, cpuSeconds >= previous.cpuSeconds else { return nil }
        func delta(_ current: UInt64, _ old: UInt64) -> UInt64 { current >= old ? current - old : 0 }
        let energy = cpuEnergyNanojoules.flatMap { current in
            previous.cpuEnergyNanojoules.map { Double(delta(current, $0)) / 1_000_000_000 }
        }
        return ResourceUsageInterval(
            timestamp: timestamp, elapsedSeconds: elapsed,
            cpuPercent: (cpuSeconds - previous.cpuSeconds) / elapsed * 100,
            interruptWakeupsPerSecond: Double(delta(interruptWakeups, previous.interruptWakeups)) / elapsed,
            diskReadBytes: delta(diskReadBytes, previous.diskReadBytes),
            diskWriteBytes: delta(diskWriteBytes, previous.diskWriteBytes),
            footprintBytes: footprintBytes, cpuEnergyJoules: energy, context: context
        )
    }
}

public struct ResourceUsageInterval: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let elapsedSeconds: Double
    /// 100% is one fully occupied core, not the whole machine.
    public let cpuPercent: Double
    public let interruptWakeupsPerSecond: Double
    public let diskReadBytes: UInt64
    public let diskWriteBytes: UInt64
    public let footprintBytes: UInt64
    /// Kernel CPU energy accounting, when supported; not Energy Impact.
    public let cpuEnergyJoules: Double?
    public let context: ResourceCaptureContext
}

/// Attempts, including failed captures, consume the budget. All deadlines use
/// monotonic time so a wall-clock correction cannot defeat the cooldown.
struct ResourceSpikePolicy {
    var cooldown: TimeInterval = 300
    var maxCapturesPerHour = 6
    private var attempts: [Double] = []
    private var consecutiveHighSamples = 0

    mutating func resetStreak() { consecutiveHighSamples = 0 }

    mutating func restoreAttemptAges(_ ages: [TimeInterval], uptime: Double) {
        attempts = ages.filter { $0 < 3600 }.map { uptime - max(0, $0) }.sorted()
    }

    mutating func shouldCapture(cpuPercent: Double, context: ResourceCaptureContext,
                                uptime: Double) -> Bool {
        guard cpuPercent.isFinite, cpuPercent >= 0 else { resetStreak(); return false }
        let threshold = context.activity == "hidden" ? 20.0 : 50.0
        consecutiveHighSamples = cpuPercent >= threshold ? consecutiveHighSamples + 1 : 0
        attempts.removeAll { uptime - $0 >= 3600 }
        guard cpuPercent >= 100 || consecutiveHighSamples >= 2 else { return false }
        guard attempts.count < maxCapturesPerHour,
              attempts.last.map({ uptime - $0 >= cooldown }) ?? true else { return false }
        attempts.append(uptime)
        resetStreak()
        return true
    }
}

public struct ResourceSpikeCaptureRecord: Codable, Equatable, Sendable {
    public let id: String
    public let createdAt: Date
    public let processID: Int32
    public let appVersion: String
    public let build: String
    public let processUptimeSeconds: Double
    public let trigger: ResourceUsageInterval
    public let recentSamples: [ResourceUsageInterval]
    public var status: String
    public var error: String?
    public var stackFile: String?
    public var stackTruncated: Bool
}

/// Capture directories contain JSON metadata and an optional stack.txt. No
/// terminal text, transcript, environment, or command arguments are recorded.
public struct ResourceSpikeCaptureStore: Sendable {
    public let directoryURL: URL
    public var maxCaptures = 20
    public var retentionDays = 14
    public var maxStackBytes = 2 * 1024 * 1024

    public init(directoryURL: URL) { self.directoryURL = directoryURL }

    public static func defaultDirectoryURL(host: HostRuntimeContext) -> URL {
        PerformanceEventStore.defaultDatabaseURL(host: host).deletingLastPathComponent()
            .appendingPathComponent("Diagnostics/CPU", isDirectory: true)
    }

    public func captureDirectory(id: String) -> URL {
        directoryURL.appendingPathComponent(id, isDirectory: true)
    }

    public func prepare(_ record: ResourceSpikeCaptureRecord) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try prune(now: record.createdAt, keeping: max(0, maxCaptures - 1))
        try FileManager.default.createDirectory(at: captureDirectory(id: record.id),
                                                 withIntermediateDirectories: false,
                                                 attributes: [.posixPermissions: 0o700])
        try save(record)
    }

    public func save(_ record: ResourceSpikeCaptureRecord) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = captureDirectory(id: record.id).appendingPathComponent("capture.json")
        try encoder.encode(record).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Read at most the bounded prefix, even if sample produced a large graph.
    public func finishStack(id: String, temporaryURL: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: temporaryURL)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporaryURL) }
        let bytes = try handle.read(upToCount: maxStackBytes + 1) ?? Data()
        guard !bytes.isEmpty else {
            throw NSError(domain: "BanyanResourceCapture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "sample produced an empty stack"])
        }
        let truncated = bytes.count > maxStackBytes
        let url = captureDirectory(id: id).appendingPathComponent("stack.txt")
        try Data(bytes.prefix(maxStackBytes)).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return truncated
    }

    public func records(since: Date) -> [ResourceSpikeCaptureRecord] {
        entries().compactMap { entry in
            guard let data = try? Data(contentsOf: entry.appendingPathComponent("capture.json")) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(ResourceSpikeCaptureRecord.self, from: data)
        }.filter { $0.createdAt >= since }.sorted { $0.createdAt > $1.createdAt }
    }

    public func prune(now: Date = Date(), keeping: Int? = nil) throws {
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86400)
        // Include incomplete/corrupt records left by a crash; directory mtime is
        // enough to bound storage even when metadata cannot be decoded.
        let sorted = entries().map { url in
            (url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
        }.sorted { $0.1 > $1.1 }
        for (index, entry) in sorted.enumerated() where index >= (keeping ?? maxCaptures) || entry.1 < cutoff {
            try FileManager.default.removeItem(at: entry.0)
        }
    }

    private func entries() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directoryURL,
                        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey])) ?? []
        return urls.filter { url in
            guard UUID(uuidString: url.lastPathComponent) != nil,
                  let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
            return values.isDirectory == true && values.isSymbolicLink != true
        }
    }
}

#if os(macOS)
/// Only polls this process's kernel counters. No ps/tmux scan and no file writes
/// between spikes. The timer and capture worker never depend on the main queue.
public final class ResourceSpikeMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.banyan.resource-monitor", qos: .utility)
    private let captureQueue = DispatchQueue(label: "app.banyan.resource-capture", qos: .utility)
    private let store: ResourceSpikeCaptureStore
    private let telemetry: PerformanceTelemetry
    private let environment: [String: String]
    private let appVersion: String
    private let build: String
    private let processID = getpid()
    private var launchedAt = ProcessInfo.processInfo.systemUptime
    private var context = ResourceCaptureContext()
    private var timer: DispatchSourceTimer?
    private var previous: ProcessResourceSample?
    private var history: [ResourceUsageInterval] = []
    private var policy = ResourceSpikePolicy()
    private var isCapturing = false

    public init(store: ResourceSpikeCaptureStore, telemetry: PerformanceTelemetry,
                environment: [String: String], appVersion: String, build: String) {
        self.store = store
        self.telemetry = telemetry
        self.environment = environment
        self.appVersion = appVersion
        self.build = build
    }

    deinit { timer?.cancel() }

    public func start(context: ResourceCaptureContext) {
        queue.async { [weak self] in
            guard let self else { return }
            self.context = context
            guard self.timer == nil else { self.schedule(); return }
            try? self.store.prune()
            let now = Date()
            self.policy.restoreAttemptAges(
                self.store.records(since: now.addingTimeInterval(-3600)).map { now.timeIntervalSince($0.createdAt) },
                uptime: ProcessInfo.processInfo.systemUptime
            )
            self.previous = Self.readCounters(pid: self.processID)
            if let start = self.previous?.processStartUptimeSeconds { self.launchedAt = start }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            self.schedule()
            timer.resume()
        }
    }

    public func update(context: ResourceCaptureContext) {
        queue.async { [weak self] in
            guard let self, self.context != context else { return }
            // Do not label a foreground interval as background after a switch.
            if self.context.activity != context.activity {
                self.previous = nil
                self.policy.resetStreak()
            }
            let cadenceChanged = self.context.samplingInterval != context.samplingInterval
            self.context = context
            if cadenceChanged { self.schedule() }
        }
    }

    private func schedule() {
        let interval = context.samplingInterval
        timer?.schedule(deadline: .now() + interval, repeating: interval,
                        leeway: .milliseconds(Int(interval * 100)))
    }

    private func tick() {
        // Profiling affects the target's counters. Omit it and re-baseline when
        // finished so the diagnostic does not recursively trigger itself.
        guard !isCapturing else { return }
        guard let sample = Self.readCounters(pid: processID) else {
            previous = nil
            policy.resetStreak()
            return
        }
        defer { previous = sample }
        guard let previous, let interval = sample.interval(since: previous, context: context) else {
            policy.resetStreak()
            return
        }
        history.append(interval)
        if history.count > 60 { history.removeFirst(history.count - 60) }
        guard policy.shouldCapture(cpuPercent: interval.cpuPercent, context: context,
                                   uptime: sample.uptimeSeconds) else { return }
        isCapturing = true
        let record = ResourceSpikeCaptureRecord(
            id: UUID().uuidString, createdAt: sample.timestamp, processID: processID,
            appVersion: appVersion, build: build,
            processUptimeSeconds: max(0, sample.uptimeSeconds - launchedAt),
            trigger: interval, recentSamples: history, status: "capturing",
            error: nil, stackFile: nil, stackTruncated: false
        )
        captureQueue.async { [weak self] in
            guard let self else { return }
            self.capture(record)
            self.queue.async { [weak self] in
                self?.isCapturing = false
                self?.previous = nil
                self?.policy.resetStreak()
            }
        }
    }

    func capture(_ initial: ResourceSpikeCaptureRecord) {
        var record = initial
        let directory = store.captureDirectory(id: record.id)
        let rawURL = directory.appendingPathComponent("sample.partial")
        defer { try? FileManager.default.removeItem(at: rawURL) }
        do {
            try store.prepare(record)
            // sample is a separate child; our own resource counters exclude it.
            // 10ms rather than 1ms sampling limits the profiling overhead.
            let output = try SubprocessRunner.run(
                arguments: ["/usr/bin/sample", String(record.processID), "3", "10", "-file", rawURL.path],
                cwd: directory.path, environment: environment, timeout: 15
            )
            guard output.terminationStatus == 0 else {
                throw NSError(domain: "BanyanResourceCapture", code: Int(output.terminationStatus),
                              userInfo: [NSLocalizedDescriptionKey: "sample exited with status \(output.terminationStatus)"])
            }
            record.stackTruncated = try store.finishStack(id: record.id, temporaryURL: rawURL)
            record.stackFile = "stack.txt"
            record.status = "complete"
        } catch {
            record.status = "failed"
            record.error = String(error.localizedDescription.prefix(512))
        }
        do { try store.save(record) }
        catch { NSLog("Banyan failed to save CPU capture: %@", error.localizedDescription) }
        telemetry.recordDurationLocalIfSlow(
            "resource.cpu_spike", durationMS: record.trigger.cpuPercent / 100 * record.trigger.elapsedSeconds * 1000,
            sessionID: record.trigger.context.selectedSessionID, correlationID: record.id,
            detail: "cpu=\(String(format: "%.1f", record.trigger.cpuPercent))% activity=\(record.trigger.context.activity) status=\(record.status) capture=\(directory.path)"
        )
    }

    static func readCounters(pid: Int32) -> ProcessResourceSample? {
        let uptime = ProcessInfo.processInfo.systemUptime
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        func seconds(_ user: UInt64, _ system: UInt64) -> Double {
            (Double(user) + Double(system)) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
        }
        var v6 = rusage_info_v6()
        let status = withUnsafeMutablePointer(to: &v6) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
            }
        }
        if status == 0 {
            return ProcessResourceSample(uptimeSeconds: uptime, cpuSeconds: seconds(v6.ri_user_time, v6.ri_system_time),
                interruptWakeups: v6.ri_interrupt_wkups, diskReadBytes: v6.ri_diskio_bytesread,
                diskWriteBytes: v6.ri_diskio_byteswritten, footprintBytes: v6.ri_phys_footprint,
                cpuEnergyNanojoules: v6.ri_energy_nj, processStartUptimeSeconds: seconds(v6.ri_proc_start_abstime, 0))
        }
        // Older macOS kernels do not implement v6. CPU-triggered capture still
        // works; JSON explicitly omits unavailable CPU energy accounting.
        var v4 = rusage_info_v4()
        let fallback = withUnsafeMutablePointer(to: &v4) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard fallback == 0 else { return nil }
        return ProcessResourceSample(uptimeSeconds: uptime, cpuSeconds: seconds(v4.ri_user_time, v4.ri_system_time),
            interruptWakeups: v4.ri_interrupt_wkups, diskReadBytes: v4.ri_diskio_bytesread,
            diskWriteBytes: v4.ri_diskio_byteswritten, footprintBytes: v4.ri_phys_footprint,
            processStartUptimeSeconds: seconds(v4.ri_proc_start_abstime, 0))
    }
}
#endif
