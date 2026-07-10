import Foundation
import SQLite3

struct SessionSnapshot: Codable {
    let id: String
    let tmuxSessionName: String?
    let title: String
    let titleURL: String?
    let reportedTitle: String?
    let generatedTitle: String?
    let isTitlePinned: Bool
    let cwd: String
    let command: String
    let status: SessionStatus
    let tone: SessionTone
    let parentSessionID: String?
    let createdAt: Date
    let updatedAt: Date

    init(
        id: String,
        tmuxSessionName: String?,
        title: String,
        titleURL: String? = nil,
        reportedTitle: String?,
        generatedTitle: String? = nil,
        isTitlePinned: Bool = false,
        cwd: String,
        command: String,
        status: SessionStatus,
        tone: SessionTone,
        parentSessionID: String? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.tmuxSessionName = tmuxSessionName
        self.title = title
        self.titleURL = titleURL
        self.reportedTitle = reportedTitle
        self.generatedTitle = generatedTitle
        self.isTitlePinned = isTitlePinned
        self.cwd = cwd
        self.command = command
        self.status = status
        self.tone = tone
        self.parentSessionID = parentSessionID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case tmuxSessionName
        case title
        case titleURL
        case reportedTitle
        case generatedTitle
        case isTitlePinned
        case cwd
        case command
        case status
        case tone
        case parentSessionID
        case createdAt
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            tmuxSessionName: try container.decodeIfPresent(String.self, forKey: .tmuxSessionName),
            title: try container.decode(String.self, forKey: .title),
            titleURL: try container.decodeIfPresent(String.self, forKey: .titleURL),
            reportedTitle: try container.decodeIfPresent(String.self, forKey: .reportedTitle),
            generatedTitle: try container.decodeIfPresent(String.self, forKey: .generatedTitle),
            isTitlePinned: try container.decodeIfPresent(Bool.self, forKey: .isTitlePinned) ?? false,
            cwd: try container.decode(String.self, forKey: .cwd),
            command: try container.decode(String.self, forKey: .command),
            status: try container.decode(SessionStatus.self, forKey: .status),
            tone: try container.decode(SessionTone.self, forKey: .tone),
            parentSessionID: try container.decodeIfPresent(String.self, forKey: .parentSessionID),
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            updatedAt: try container.decode(Date.self, forKey: .updatedAt)
        )
    }
}

struct WorkspaceSnapshot {
    let selectedSessionID: String?
    let sortMode: SortMode
    let terminalTheme: TerminalTheme
    let terminalFontFamily: String
    let terminalFontSize: Double
}

struct LinearIssueListCacheSnapshot: Codable {
    let issues: [LinearIssueSummary]
    let workflowStates: [LinearWorkflowState]?
    let selectedIssueID: String?
    let updatedAt: Date
}

struct SessionPersistence {
    private static let linearIssueListCacheKey = "linearIssueListCache"

    private let databaseURL: URL
    private let legacyJSONURL: URL

    init(
        databaseURL: URL = SessionPersistence.defaultDatabaseURL(),
        legacyJSONURL: URL = SessionPersistence.defaultLegacyJSONURL()
    ) {
        self.databaseURL = databaseURL
        self.legacyJSONURL = legacyJSONURL
        migrateLegacyJSONIfNeeded()
    }

    func load() -> [SessionSnapshot] {
        do {
            let database = try openDatabase()
            defer { sqlite3_close(database) }
            try migrate(database)

            let sql = """
            SELECT id, tmux_session_name, title, title_url, reported_title, generated_title, is_title_pinned, cwd, command, status, tone, parent_session_id, created_at, updated_at
            FROM sessions
            ORDER BY sort_order ASC, created_at ASC
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                throw databaseError(database)
            }
            defer { sqlite3_finalize(statement) }

            var snapshots: [SessionSnapshot] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard
                    let id = columnText(statement, 0),
                    let title = columnText(statement, 2),
                    let cwd = columnText(statement, 7),
                    let command = columnText(statement, 8),
                    let rawStatus = columnText(statement, 9),
                    let status = SessionStatus(rawValue: rawStatus),
                    let rawTone = columnText(statement, 10),
                    let tone = SessionTone(rawValue: rawTone),
                    let createdAt = decodeDate(columnText(statement, 12)),
                    let updatedAt = decodeDate(columnText(statement, 13))
                else {
                    continue
                }
                snapshots.append(
                    SessionSnapshot(
                        id: id,
                        tmuxSessionName: columnText(statement, 1),
                        title: title,
                        titleURL: columnText(statement, 3),
                        reportedTitle: columnText(statement, 4),
                        generatedTitle: columnText(statement, 5),
                        isTitlePinned: sqlite3_column_int(statement, 6) != 0,
                        cwd: cwd,
                        command: command,
                        status: status,
                        tone: tone,
                        parentSessionID: columnText(statement, 11),
                        createdAt: createdAt,
                        updatedAt: updatedAt
                    )
                )
            }
            return snapshots
        } catch {
            NSLog("Banyan failed to load sessions from SQLite: \(error.localizedDescription)")
            return []
        }
    }

    func save(_ snapshots: [SessionSnapshot]) {
        do {
            let database = try openDatabase()
            defer { sqlite3_close(database) }
            try migrate(database)
            try execute(database, "BEGIN IMMEDIATE TRANSACTION")
            do {
                try execute(database, "DELETE FROM sessions")
                for (index, snapshot) in snapshots.enumerated() {
                    try upsert(snapshot, sortOrder: index, database: database)
                }
                try execute(database, "COMMIT")
            } catch {
                try? execute(database, "ROLLBACK")
                throw error
            }
        } catch {
            NSLog("Banyan failed to persist sessions to SQLite: \(error.localizedDescription)")
        }
    }

    func loadWorkspace(defaults: WorkspaceSnapshot) -> WorkspaceSnapshot {
        do {
            let database = try openDatabase()
            defer { sqlite3_close(database) }
            try migrate(database)

            let state = try loadState(database)
            return WorkspaceSnapshot(
                selectedSessionID: state["selectedSessionID"] ?? defaults.selectedSessionID,
                sortMode: state["sortMode"].flatMap(SortMode.init(rawValue:)) ?? defaults.sortMode,
                terminalTheme: TerminalTheme.fromPersistedRawValue(state["terminalTheme"]) ?? defaults.terminalTheme,
                terminalFontFamily: state["terminalFontFamily"] ?? defaults.terminalFontFamily,
                terminalFontSize: state["terminalFontSize"].flatMap(Double.init) ?? defaults.terminalFontSize
            )
        } catch {
            NSLog("Banyan failed to load workspace state from SQLite: \(error.localizedDescription)")
            return defaults
        }
    }

    func saveWorkspace(_ workspace: WorkspaceSnapshot) {
        do {
            let database = try openDatabase()
            defer { sqlite3_close(database) }
            try migrate(database)
            try execute(database, "BEGIN IMMEDIATE TRANSACTION")
            do {
                try setState("selectedSessionID", workspace.selectedSessionID, database)
                try setState("sortMode", workspace.sortMode.rawValue, database)
                try setState("terminalTheme", workspace.terminalTheme.rawValue, database)
                try setState("terminalFontFamily", workspace.terminalFontFamily, database)
                try setState("terminalFontSize", String(workspace.terminalFontSize), database)
                try execute(database, "COMMIT")
            } catch {
                try? execute(database, "ROLLBACK")
                throw error
            }
        } catch {
            NSLog("Banyan failed to persist workspace state to SQLite: \(error.localizedDescription)")
        }
    }

    func loadLinearIssueListCache() -> LinearIssueListCacheSnapshot? {
        do {
            let database = try openDatabase()
            defer { sqlite3_close(database) }
            try migrate(database)

            let state = try loadState(database)
            guard let rawCache = state[Self.linearIssueListCacheKey],
                  let data = rawCache.data(using: .utf8) else {
                return nil
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(LinearIssueListCacheSnapshot.self, from: data)
        } catch {
            NSLog("Banyan failed to load Linear issue list cache from SQLite: \(error.localizedDescription)")
            return nil
        }
    }

    func saveLinearIssueListCache(_ snapshot: LinearIssueListCacheSnapshot) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)
            guard let rawCache = String(data: data, encoding: .utf8) else { return }

            let database = try openDatabase()
            defer { sqlite3_close(database) }
            try migrate(database)
            try setState(Self.linearIssueListCacheKey, rawCache, database)
        } catch {
            NSLog("Banyan failed to persist Linear issue list cache to SQLite: \(error.localizedDescription)")
        }
    }

    private func migrateLegacyJSONIfNeeded() {
        guard FileManager.default.fileExists(atPath: legacyJSONURL.path) else { return }
        guard load().isEmpty else { return }
        guard let data = try? Data(contentsOf: legacyJSONURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshots = try? decoder.decode([SessionSnapshot].self, from: data), !snapshots.isEmpty else {
            return
        }
        save(snapshots)
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
        try execute(database, "PRAGMA foreign_keys = ON")
        try execute(database, """
        CREATE TABLE IF NOT EXISTS sessions (
            id TEXT PRIMARY KEY,
            tmux_session_name TEXT,
            title TEXT NOT NULL,
            title_url TEXT,
            reported_title TEXT,
            generated_title TEXT,
            is_title_pinned INTEGER NOT NULL DEFAULT 0,
            cwd TEXT NOT NULL,
            command TEXT NOT NULL,
            status TEXT NOT NULL,
            tone TEXT NOT NULL,
            parent_session_id TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            sort_order INTEGER NOT NULL DEFAULT 0
        )
        """)
        try? execute(database, "ALTER TABLE sessions ADD COLUMN title_url TEXT")
        try? execute(database, "ALTER TABLE sessions ADD COLUMN generated_title TEXT")
        try? execute(database, "ALTER TABLE sessions ADD COLUMN is_title_pinned INTEGER NOT NULL DEFAULT 0")
        try? execute(database, "ALTER TABLE sessions ADD COLUMN parent_session_id TEXT")
        try execute(database, """
        CREATE TABLE IF NOT EXISTS workspace_state (
            key TEXT PRIMARY KEY,
            value TEXT
        )
        """)
        try execute(database, """
        CREATE TABLE IF NOT EXISTS session_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT NOT NULL,
            kind TEXT NOT NULL,
            message TEXT,
            created_at TEXT NOT NULL
        )
        """)
    }

    private func upsert(_ snapshot: SessionSnapshot, sortOrder: Int, database: OpaquePointer) throws {
        let sql = """
        INSERT INTO sessions (
            id, tmux_session_name, title, title_url, reported_title, generated_title, is_title_pinned, cwd, command, status, tone, parent_session_id, created_at, updated_at, sort_order
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            tmux_session_name = excluded.tmux_session_name,
            title = excluded.title,
            title_url = excluded.title_url,
            reported_title = excluded.reported_title,
            generated_title = excluded.generated_title,
            is_title_pinned = excluded.is_title_pinned,
            cwd = excluded.cwd,
            command = excluded.command,
            status = excluded.status,
            tone = excluded.tone,
            parent_session_id = excluded.parent_session_id,
            created_at = excluded.created_at,
            updated_at = excluded.updated_at,
            sort_order = excluded.sort_order
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw databaseError(database)
        }
        defer { sqlite3_finalize(statement) }

        bindText(statement, 1, snapshot.id)
        bindText(statement, 2, snapshot.tmuxSessionName)
        bindText(statement, 3, snapshot.title)
        bindText(statement, 4, snapshot.titleURL)
        bindText(statement, 5, snapshot.reportedTitle)
        bindText(statement, 6, snapshot.generatedTitle)
        sqlite3_bind_int(statement, 7, snapshot.isTitlePinned ? 1 : 0)
        bindText(statement, 8, snapshot.cwd)
        bindText(statement, 9, snapshot.command)
        bindText(statement, 10, snapshot.status.rawValue)
        bindText(statement, 11, snapshot.tone.rawValue)
        bindText(statement, 12, snapshot.parentSessionID)
        bindText(statement, 13, encodeDate(snapshot.createdAt))
        bindText(statement, 14, encodeDate(snapshot.updatedAt))
        sqlite3_bind_int64(statement, 15, Int64(sortOrder))

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw databaseError(database)
        }
    }

    private func loadState(_ database: OpaquePointer) throws -> [String: String] {
        let sql = "SELECT key, value FROM workspace_state"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw databaseError(database)
        }
        defer { sqlite3_finalize(statement) }

        var result: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let key = columnText(statement, 0) else { continue }
            result[key] = columnText(statement, 1)
        }
        return result
    }

    private func setState(_ key: String, _ value: String?, _ database: OpaquePointer) throws {
        if let value {
            let sql = """
            INSERT INTO workspace_state (key, value)
            VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                throw databaseError(database)
            }
            defer { sqlite3_finalize(statement) }
            bindText(statement, 1, key)
            bindText(statement, 2, value)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw databaseError(database)
            }
        } else {
            let sql = "DELETE FROM workspace_state WHERE key = ?"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                throw databaseError(database)
            }
            defer { sqlite3_finalize(statement) }
            bindText(statement, 1, key)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw databaseError(database)
            }
        }
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

    private func encodeDate(_ date: Date) -> String {
        Self.dateFormatter.string(from: date)
    }

    private func decodeDate(_ value: String?) -> Date? {
        value.flatMap { Self.dateFormatter.date(from: $0) }
    }

    static func defaultDatabaseURL() -> URL {
        let base = applicationSupportURL()
        return base.appendingPathComponent("Banyan/state.sqlite")
    }

    static func defaultLegacyJSONURL() -> URL {
        let base = applicationSupportURL()
        return base.appendingPathComponent("Banyan/sessions.json")
    }

    private static func applicationSupportURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
    }

    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
