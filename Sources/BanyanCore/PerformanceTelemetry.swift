import Foundation
import CSQLite

public struct PerformanceEvent: Codable, Equatable {
    public let id: Int64?
    public let name: String
    public let sessionID: String?
    public let correlationID: String?
    public let durationMS: Double
    public let detail: String?
    public let createdAt: Date

    public init(
        id: Int64? = nil,
        name: String,
        sessionID: String? = nil,
        correlationID: String? = nil,
        durationMS: Double,
        detail: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.sessionID = sessionID
        self.correlationID = correlationID
        self.durationMS = durationMS
        self.detail = detail
        self.createdAt = createdAt
    }
}

public struct PerformanceMetricSummary: Codable, Equatable {
    public let name: String
    public let count: Int
    public let averageMS: Double
    public let p50MS: Double
    public let p75MS: Double
    public let p95MS: Double
    public let p99MS: Double
    public let maxMS: Double
    public let slowCount: Int
    public let thresholdMS: Double
}

public struct PerformanceReport: Codable, Equatable {
    public let generatedAt: Date
    public let since: Date
    public let eventCount: Int
    public let summaries: [PerformanceMetricSummary]
    public let recentSlowEvents: [PerformanceEvent]
}

public struct PerformanceEventStore {
    public var retentionDays: Int
    public var maxEvents: Int

    private let databaseURL: URL
    private let writer = WriteConnection()

    /// Prune is a full scan and sort of the capped table, so it must not run per
    /// insert. `terminal.draw` alone records several events a second, and the
    /// table sits pinned at `maxEvents`, which made every one of those a 10k-row
    /// scan plus a journal fsync — disk churn that dominated the app's energy
    /// score. Amortise it instead; overshooting the cap by this much is harmless.
    private static let insertsBetweenPrunes = 500

    /// Holds the writer's long-lived handle. `record` is only ever called from
    /// `PerformanceTelemetry`'s serial queue, so the box needs no locking of its
    /// own; struct copies deliberately share it.
    private final class WriteConnection: @unchecked Sendable {
        var handle: OpaquePointer?
        var insertsSincePrune = 0

        deinit {
            if let handle {
                sqlite3_close(handle)
            }
        }
    }

    public init(
        databaseURL: URL,
        retentionDays: Int = 14,
        maxEvents: Int = 10_000
    ) {
        self.databaseURL = databaseURL
        self.retentionDays = retentionDays
        self.maxEvents = maxEvents
    }

    public func record(_ event: PerformanceEvent) {
        record([event])
    }

    /// Writes a whole batch under one transaction. Prefer this over repeated
    /// single-event calls: an `INSERT` outside an explicit transaction is its own
    /// WAL commit, so a burst of terminal draws became a burst of disk writes.
    public func record(_ events: [PerformanceEvent]) {
        guard !events.isEmpty else { return }
        do {
            let database = try writableDatabase()
            try insert(events, database: database)
            writer.insertsSincePrune += events.count
            if writer.insertsSincePrune >= Self.insertsBetweenPrunes {
                writer.insertsSincePrune = 0
                try prune(database)
            }
        } catch {
            NSLog("Banyan failed to record performance events: \(error.localizedDescription)")
        }
    }

    /// Opens the write handle once and keeps it. WAL plus `synchronous=NORMAL`
    /// suits disposable diagnostic data: no journal file is created and torn down
    /// per transaction, and writes are not fsynced individually.
    private func writableDatabase() throws -> OpaquePointer {
        if let handle = writer.handle {
            return handle
        }
        let database = try openDatabase()
        try execute(database, "PRAGMA journal_mode=WAL")
        try execute(database, "PRAGMA synchronous=NORMAL")
        try migrate(database)
        // The table may already be over cap from a previous run.
        try prune(database)
        writer.handle = database
        return database
    }

    public func loadEvents(since: Date) -> [PerformanceEvent] {
        do {
            let database = try openDatabase()
            defer { sqlite3_close(database) }
            try migrate(database)

            let sql = """
            SELECT id, name, session_id, correlation_id, duration_ms, detail, created_at
            FROM performance_events
            WHERE created_at >= ?
            ORDER BY created_at ASC
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                throw databaseError(database)
            }
            defer { sqlite3_finalize(statement) }

            bindText(statement, 1, Self.encodeDate(since))
            var events: [PerformanceEvent] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard
                    let name = columnText(statement, 1),
                    let createdAt = Self.decodeDate(columnText(statement, 6))
                else {
                    continue
                }
                events.append(PerformanceEvent(
                    id: sqlite3_column_int64(statement, 0),
                    name: name,
                    sessionID: columnText(statement, 2),
                    correlationID: columnText(statement, 3),
                    durationMS: sqlite3_column_double(statement, 4),
                    detail: columnText(statement, 5),
                    createdAt: createdAt
                ))
            }
            return events
        } catch {
            NSLog("Banyan failed to load performance events: \(error.localizedDescription)")
            return []
        }
    }

    public func report(since: Date = Date().addingTimeInterval(-7 * 24 * 60 * 60)) -> PerformanceReport {
        let events = loadEvents(since: since)
        let summaries = Dictionary(grouping: events, by: \.name)
            .map { name, grouped in
                Self.summarize(name: name, events: grouped)
            }
            .sorted {
                if $0.p95MS == $1.p95MS {
                    return $0.name < $1.name
                }
                return $0.p95MS > $1.p95MS
            }
        let recentSlowEvents = events
            .filter { $0.durationMS >= Self.thresholdMS(for: $0.name) }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(20)
        return PerformanceReport(
            generatedAt: Date(),
            since: since,
            eventCount: events.count,
            summaries: summaries,
            recentSlowEvents: Array(recentSlowEvents)
        )
    }

    public func formattedReport(since: Date = Date().addingTimeInterval(-7 * 24 * 60 * 60)) -> String {
        let report = report(since: since)
        guard !report.summaries.isEmpty else {
            return "No Banyan performance events since \(Self.displayDate(report.since))."
        }

        var lines: [String] = []
        lines.append("Banyan performance report since \(Self.displayDate(report.since))")
        lines.append("Events: \(report.eventCount)")
        lines.append("")
        lines.append(Self.tableRow(["metric", "count", "avg", "p50", "p75", "p95", "p99", "max", "slow"]))
        lines.append(Self.tableRow(["------", "-----", "---", "---", "---", "---", "---", "---", "----"]))
        for summary in report.summaries {
            lines.append(Self.tableRow([
                summary.name,
                "\(summary.count)",
                Self.ms(summary.averageMS),
                Self.ms(summary.p50MS),
                Self.ms(summary.p75MS),
                Self.ms(summary.p95MS),
                Self.ms(summary.p99MS),
                Self.ms(summary.maxMS),
                "\(summary.slowCount)"
            ]))
        }

        if !report.recentSlowEvents.isEmpty {
            lines.append("")
            lines.append("Recent slow events:")
            for event in report.recentSlowEvents.prefix(10) {
                let session = event.sessionID.map { " session=\($0)" } ?? ""
                let detail = event.detail.map { " \($0)" } ?? ""
                lines.append("- \(Self.displayDate(event.createdAt)) \(event.name) \(Self.ms(event.durationMS))\(session)\(detail)")
            }
        }

        // Without this, a sampled metric's count reads as the true event rate.
        let sampledNotes = report.summaries
            .compactMap { summary -> String? in
                guard let policy = PerformanceSampler.defaultPolicies[summary.name] else { return nil }
                return "- \(summary.name): every event >= \(Self.ms(policy.alwaysRecordAtOrAboveMS)) recorded, "
                    + "faster ones 1 in \(policy.sampleRate). Multiply counts below that bar by ~\(policy.sampleRate)."
            }
            .sorted()
        if !sampledNotes.isEmpty {
            lines.append("")
            lines.append("Sampled metrics:")
            lines.append(contentsOf: sampledNotes)
        }
        return lines.joined(separator: "\n")
    }

    public static func defaultDatabaseURL(
        environment: [String: String],
        homeDirectory: URL
    ) -> URL {
        BanyanDataDirectory.url(
            for: "Banyan/state.sqlite",
            environment: environment,
            homeDirectory: homeDirectory
        )
    }

    public static func defaultDatabaseURL(host: HostRuntimeContext) -> URL {
        defaultDatabaseURL(
            environment: host.environment,
            homeDirectory: host.homeDirectory
        )
    }

    public static func thresholdMS(for name: String) -> Double {
        switch name {
        case "session_switch.total": return 1_000
        case "session_switch.to_terminal_ready": return 500
        case "session_switch.to_first_output": return 1_500
        case "terminal.ready_wait": return 250
        case "terminal.install_view": return 100
        case "terminal.start_client": return 500
        case "terminal.reattach_client": return 750
        case "terminal.draw": return 16
        case "terminal.blank_recovery": return 1
        case "tmux.refresh_clients": return 250
        case "selected_context.resolve": return 500
        case "supervisor.tick": return 150
        case "supervisor.session": return 150
        default: return 500
        }
    }

    private static func summarize(name: String, events: [PerformanceEvent]) -> PerformanceMetricSummary {
        let durations = events.map(\.durationMS).sorted()
        let total = durations.reduce(0, +)
        let threshold = thresholdMS(for: name)
        return PerformanceMetricSummary(
            name: name,
            count: durations.count,
            averageMS: total / Double(max(durations.count, 1)),
            p50MS: percentile(0.50, durations),
            p75MS: percentile(0.75, durations),
            p95MS: percentile(0.95, durations),
            p99MS: percentile(0.99, durations),
            maxMS: durations.last ?? 0,
            slowCount: durations.filter { $0 >= threshold }.count,
            thresholdMS: threshold
        )
    }

    private static func percentile(_ percentile: Double, _ sortedValues: [Double]) -> Double {
        guard !sortedValues.isEmpty else { return 0 }
        guard sortedValues.count > 1 else { return sortedValues[0] }
        let index = Int((Double(sortedValues.count - 1) * percentile).rounded(.up))
        return sortedValues[min(max(index, 0), sortedValues.count - 1)]
    }

    private func openDatabase() throws -> OpaquePointer {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
            throw databaseError(database)
        }
        return database
    }

    private func migrate(_ database: OpaquePointer) throws {
        try execute(database, """
        CREATE TABLE IF NOT EXISTS performance_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            session_id TEXT,
            correlation_id TEXT,
            duration_ms REAL NOT NULL,
            detail TEXT,
            created_at TEXT NOT NULL
        )
        """)
        try execute(database, "CREATE INDEX IF NOT EXISTS idx_performance_events_created_at ON performance_events(created_at)")
        try execute(database, "CREATE INDEX IF NOT EXISTS idx_performance_events_name ON performance_events(name)")
    }

    /// One transaction and one prepared statement for the whole batch, so a flush
    /// of N events costs a single WAL commit instead of N.
    private func insert(_ events: [PerformanceEvent], database: OpaquePointer) throws {
        let sql = """
        INSERT INTO performance_events (name, session_id, correlation_id, duration_ms, detail, created_at)
        VALUES (?, ?, ?, ?, ?, ?)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw databaseError(database)
        }
        defer { sqlite3_finalize(statement) }

        try execute(database, "BEGIN IMMEDIATE")
        do {
            for event in events {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bindText(statement, 1, event.name)
                bindText(statement, 2, event.sessionID)
                bindText(statement, 3, event.correlationID)
                sqlite3_bind_double(statement, 4, event.durationMS)
                bindText(statement, 5, event.detail)
                bindText(statement, 6, Self.encodeDate(event.createdAt))

                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw databaseError(database)
                }
            }
            try execute(database, "COMMIT")
        } catch {
            // Leaving the transaction open would fail every later BEGIN on this
            // long-lived handle, so telemetry would stop recording for good.
            try? execute(database, "ROLLBACK")
            throw error
        }
    }

    private func prune(_ database: OpaquePointer) throws {
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 24 * 60 * 60)
        try execute(database, "DELETE FROM performance_events WHERE created_at < '\(Self.encodeDate(cutoff))'")
        try execute(database, """
        DELETE FROM performance_events
        WHERE id NOT IN (
            SELECT id FROM performance_events
            ORDER BY created_at DESC, id DESC
            LIMIT \(maxEvents)
        )
        """)
    }

    private func execute(_ database: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown SQLite error"
            sqlite3_free(error)
            throw NSError(domain: "BanyanSQLite", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func databaseError(_ database: OpaquePointer?) -> NSError {
        let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error"
        return NSError(domain: "BanyanSQLite", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func bindText(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: text)
    }

    private static func tableRow(_ values: [String]) -> String {
        values.joined(separator: "\t")
    }

    private static func ms(_ value: Double) -> String {
        "\(Int(value.rounded()))ms"
    }

    private static func displayDate(_ date: Date) -> String {
        displayDateFormatter.string(from: date)
    }

    private static func encodeDate(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    private static func decodeDate(_ value: String?) -> Date? {
        value.flatMap { dateFormatter.date(from: $0) }
    }

    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let displayDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

/// Thins out high-frequency metrics without losing their slow tail.
///
/// `terminal.draw`'s 16ms report threshold is one frame at 60Hz, so during
/// streaming output nearly every draw clears it — recording them all is what
/// turned diagnostics into a steady stream of disk writes. Draws slow enough to
/// be a visible hitch stay at or above `alwaysRecordAtOrAboveMS` and are never
/// sampled out; only the routine band below it is thinned to one in
/// `sampleRate`. Metrics absent from the policy table are always recorded in
/// full, so `supervisor.tick` and `switcher.switch_visible` keep every sample.
struct PerformanceSampler {
    struct Policy: Equatable {
        /// At or above this duration an event is always recorded, with full detail.
        let alwaysRecordAtOrAboveMS: Double
        /// One in every `sampleRate` events below that duration is kept.
        let sampleRate: Int
    }

    enum Decision: Equatable {
        /// Record the event, appending `detailSuffix` to its detail when non-nil.
        case record(detailSuffix: String?)
        case drop
    }

    /// 50ms is roughly three dropped frames: past that a draw is a hitch worth
    /// investigating, below it the sample only matters in aggregate.
    static let defaultPolicies: [String: Policy] = [
        "terminal.draw": Policy(alwaysRecordAtOrAboveMS: 50, sampleRate: 8)
    ]

    private let policies: [String: Policy]
    private var counters: [String: Int] = [:]

    init(policies: [String: Policy] = PerformanceSampler.defaultPolicies) {
        self.policies = policies
    }

    mutating func decide(name: String, durationMS: Double) -> Decision {
        guard let policy = policies[name], policy.sampleRate > 1 else {
            return .record(detailSuffix: nil)
        }
        guard durationMS < policy.alwaysRecordAtOrAboveMS else {
            return .record(detailSuffix: nil)
        }
        let seen = (counters[name] ?? 0) + 1
        guard seen >= policy.sampleRate else {
            counters[name] = seen
            return .drop
        }
        counters[name] = 0
        // Tag the survivor so a reader knows this metric's count is scaled down.
        return .record(detailSuffix: "sample=1/\(policy.sampleRate)")
    }
}

public final class PerformanceTelemetry: @unchecked Sendable {
    private struct ActiveSpan {
        let name: String
        let sessionID: String?
        let correlationID: String?
        let detail: String?
        let startedAt: DispatchTime
    }

    private struct ActiveSessionSwitch {
        let sessionID: String
        let correlationID: String
        let detail: String
        let startedAt: DispatchTime
        var didRecordTerminalReady: Bool
        var didRecordFirstOutput: Bool
    }

    private let store: PerformanceEventStore
    private let queue = DispatchQueue(label: "app.banyan.performance-telemetry", qos: .utility)
    private var activeSpans: [String: ActiveSpan] = [:]
    private var activeSwitches: [String: ActiveSessionSwitch] = [:]
    /// Buffered until a flush. Everything below is touched only on `queue`, which
    /// is serial, so none of it needs its own locking.
    private var pendingEvents: [PerformanceEvent] = []
    private var isFlushScheduled = false
    private var sampler = PerformanceSampler()
    public var axiomExporter: AxiomExporter?

    /// Deliberately a one-shot `asyncAfter` armed only while the buffer is
    /// non-empty, not a repeating timer: an idle app schedules nothing at all and
    /// never wakes for a flush it has no work for.
    static let flushInterval: TimeInterval = 5
    /// Caps how many events a crash can lose, and bounds the transaction size.
    static let maxBufferedEvents = 64

    public init(store: PerformanceEventStore, axiomExporter: AxiomExporter? = nil) {
        self.store = store
        self.axiomExporter = axiomExporter
    }

    /// Safe to touch the buffer directly: deinit means no references survive, and
    /// every queued block holds only a weak one, so nothing else can be running.
    deinit {
        flushPendingLocked()
    }

    @discardableResult
    public func beginSpan(
        _ name: String,
        sessionID: String? = nil,
        correlationID: String? = nil,
        detail: String? = nil
    ) -> String {
        let id = UUID().uuidString
        let span = ActiveSpan(
            name: name,
            sessionID: sessionID,
            correlationID: correlationID,
            detail: detail,
            startedAt: .now()
        )
        queue.async { [weak self] in
            self?.activeSpans[id] = span
        }
        return id
    }

    public func endSpan(_ id: String, detail: String? = nil) {
        queue.async { [weak self] in
            guard let self, let span = self.activeSpans.removeValue(forKey: id) else { return }
            self.recordLocked(
                name: span.name,
                sessionID: span.sessionID,
                correlationID: span.correlationID,
                durationMS: Self.elapsedMS(since: span.startedAt),
                detail: detail ?? span.detail
            )
        }
    }

    public func recordDuration(
        _ name: String,
        durationMS: Double,
        sessionID: String? = nil,
        correlationID: String? = nil,
        detail: String? = nil
    ) {
        queue.async { [weak self] in
            self?.recordLocked(
                name: name,
                sessionID: sessionID,
                correlationID: correlationID,
                durationMS: durationMS,
                detail: detail
            )
        }
    }

    /// High-frequency spans such as terminal draws should not turn diagnostics
    /// into a steady stream of SQLite writes. Retain only the samples that need
    /// investigation; aggregate timing remains available from the slower spans.
    public func recordDurationIfSlow(
        _ name: String,
        durationMS: Double,
        sessionID: String? = nil,
        correlationID: String? = nil,
        detail: String? = nil
    ) {
        guard Self.shouldRecordDuration(name, durationMS: durationMS) else { return }
        recordDuration(
            name,
            durationMS: durationMS,
            sessionID: sessionID,
            correlationID: correlationID,
            detail: detail
        )
    }

    /// Local-only variant for high-frequency supervisor ticks. Keeps SQLite
    /// `banyanctl perf report` useful but avoids per-tick Axiom log ingestion.
    public func recordDurationLocalIfSlow(
        _ name: String,
        durationMS: Double,
        sessionID: String? = nil,
        correlationID: String? = nil,
        detail: String? = nil
    ) {
        guard Self.shouldRecordDuration(name, durationMS: durationMS) else { return }
        queue.async { [weak self] in
            self?.recordLocked(
                name: name,
                sessionID: sessionID,
                correlationID: correlationID,
                durationMS: durationMS,
                detail: detail,
                sendToAxiom: false
            )
        }
    }

    public static func shouldRecordDuration(_ name: String, durationMS: Double) -> Bool {
        durationMS >= PerformanceEventStore.thresholdMS(for: name)
    }

    public func beginSessionSwitch(
        from oldSessionID: String?,
        to newSessionID: String?,
        visibleSessionCount: Int
    ) {
        guard let newSessionID else { return }
        let correlationID = UUID().uuidString
        let detail = [
            oldSessionID.map { "from=\($0)" },
            "to=\(newSessionID)",
            "visible=\(visibleSessionCount)"
        ].compactMap { $0 }.joined(separator: " ")
        queue.async { [weak self] in
            guard let self else { return }
            self.expireOldSwitchesLocked()
            self.activeSwitches[newSessionID] = ActiveSessionSwitch(
                sessionID: newSessionID,
                correlationID: correlationID,
                detail: detail,
                startedAt: .now(),
                didRecordTerminalReady: false,
                didRecordFirstOutput: false
            )
        }
    }

    public func noteSessionTerminalReady(sessionID: String) {
        queue.async { [weak self] in
            guard let self, var active = self.activeSwitches[sessionID], !active.didRecordTerminalReady else {
                return
            }
            let duration = Self.elapsedMS(since: active.startedAt)
            guard Self.isWithinSwitchCap(duration) else {
                // Idle/abandoned switch: the elapsed time is idle time, not switch
                // cost. Drop it so it can't inflate the switch percentiles.
                self.activeSwitches.removeValue(forKey: sessionID)
                return
            }
            self.recordLocked(
                name: "session_switch.to_terminal_ready",
                sessionID: sessionID,
                correlationID: active.correlationID,
                durationMS: duration,
                detail: active.detail
            )
            self.recordLocked(
                name: "session_switch.total",
                sessionID: sessionID,
                correlationID: active.correlationID,
                durationMS: duration,
                detail: active.detail
            )
            active.didRecordTerminalReady = true
            self.activeSwitches[sessionID] = active
        }
    }

    public func noteSessionFirstOutput(sessionID: String) {
        queue.async { [weak self] in
            guard let self, var active = self.activeSwitches[sessionID], !active.didRecordFirstOutput else {
                return
            }
            let duration = Self.elapsedMS(since: active.startedAt)
            guard Self.isWithinSwitchCap(duration) else {
                // `to_first_output` measures time until the session's *next* output,
                // which is unbounded for a quiet session. Past the cap it's idle
                // time, not switch cost, so discard the whole span.
                self.activeSwitches.removeValue(forKey: sessionID)
                return
            }
            self.recordLocked(
                name: "session_switch.to_first_output",
                sessionID: sessionID,
                correlationID: active.correlationID,
                durationMS: duration,
                detail: active.detail
            )
            active.didRecordFirstOutput = true
            self.activeSwitches[sessionID] = active
            if active.didRecordTerminalReady {
                self.activeSwitches.removeValue(forKey: sessionID)
            }
        }
    }

    public static func elapsedMS(since start: DispatchTime, until end: DispatchTime = .now()) -> Double {
        Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }

    private func recordLocked(
        name: String,
        sessionID: String?,
        correlationID: String?,
        durationMS: Double,
        detail: String?,
        sendToAxiom: Bool = true
    ) {
        guard case .record(let detailSuffix) = sampler.decide(name: name, durationMS: durationMS) else {
            return
        }
        let event = PerformanceEvent(
            name: name,
            sessionID: sessionID,
            correlationID: correlationID,
            durationMS: durationMS,
            detail: Self.appending(detailSuffix, to: detail)
        )
        pendingEvents.append(event)
        scheduleFlushLocked()
        // supervisor.* is high-frequency; keep in local SQLite for `banyanctl perf`
        // but don't pay per-tick Axiom log ingestion. Switch to metrics if needed.
        let isSupervisor = name.hasPrefix("supervisor.")
        if sendToAxiom && !isSupervisor {
            axiomExporter?.sendPerformanceEvent(event)
        }
    }

    private static func appending(_ suffix: String?, to detail: String?) -> String? {
        guard let suffix else { return detail }
        guard let detail, !detail.isEmpty else { return suffix }
        return "\(detail) \(suffix)"
    }

    /// How many events are waiting to be written. Reading it drains everything
    /// already queued, so it also serves as a barrier. Must not be called from `queue`.
    var bufferedEventCount: Int {
        queue.sync { pendingEvents.count }
    }

    /// Writes the buffer out without waiting. Safe to call from any thread.
    public func flushPendingEvents() {
        queue.async { [weak self] in
            self?.flushPendingLocked()
        }
    }

    /// Blocks until the buffer is on disk. For app termination, where a queued
    /// async flush would never run. Must not be called from `queue`.
    public func flushPendingEventsAndWait() {
        queue.sync {
            flushPendingLocked()
        }
    }

    private func scheduleFlushLocked() {
        if pendingEvents.count >= Self.maxBufferedEvents {
            flushPendingLocked()
            return
        }
        guard !isFlushScheduled else { return }
        isFlushScheduled = true
        queue.asyncAfter(deadline: .now() + Self.flushInterval) { [weak self] in
            guard let self else { return }
            self.isFlushScheduled = false
            self.flushPendingLocked()
        }
    }

    private func flushPendingLocked() {
        guard !pendingEvents.isEmpty else { return }
        let events = pendingEvents
        pendingEvents.removeAll(keepingCapacity: true)
        store.record(events)
    }

    /// A session switch that hasn't reached terminal-ready / first-output within
    /// this window is treated as idle or abandoned rather than slow. `to_first_output`
    /// especially measures time until the session's next output, which is unbounded
    /// for a quiet session; recording it would pollute the switch percentiles.
    static let switchMeasurementCapMS: Double = 10_000

    static func isWithinSwitchCap(_ durationMS: Double) -> Bool {
        durationMS <= switchMeasurementCapMS
    }

    private func expireOldSwitchesLocked() {
        let now = DispatchTime.now()
        activeSwitches = activeSwitches.filter { _, active in
            Self.elapsedMS(since: active.startedAt, until: now) < 60_000
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
