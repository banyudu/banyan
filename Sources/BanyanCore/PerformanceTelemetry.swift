import Foundation
import SQLite3

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
        do {
            let database = try openDatabase()
            defer { sqlite3_close(database) }
            try migrate(database)
            try insert(event, database: database)
            try prune(database)
        } catch {
            NSLog("Banyan failed to record performance event: \(error.localizedDescription)")
        }
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
        case "terminal.blank_recovery": return 1
        case "tmux.refresh_clients": return 250
        case "selected_context.resolve": return 500
        case "supervisor.tick": return 150
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

    private func insert(_ event: PerformanceEvent, database: OpaquePointer) throws {
        let sql = """
        INSERT INTO performance_events (name, session_id, correlation_id, duration_ms, detail, created_at)
        VALUES (?, ?, ?, ?, ?, ?)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw databaseError(database)
        }
        defer { sqlite3_finalize(statement) }

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

    public init(store: PerformanceEventStore) {
        self.store = store
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
        detail: String?
    ) {
        store.record(PerformanceEvent(
            name: name,
            sessionID: sessionID,
            correlationID: correlationID,
            durationMS: durationMS,
            detail: detail
        ))
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
