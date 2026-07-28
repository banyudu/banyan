import BanyanCore
import Foundation
import SQLite3

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

struct SessionPersistence: SessionPersistenceBackend {
    private static let linearIssueListCacheKey = "linearIssueListCache"

    private let databaseURL: URL
    private let sessionDatabase: SessionDatabase

    init(
        databaseURL: URL = SessionPersistence.defaultDatabaseURL(),
        legacyJSONURL: URL = SessionPersistence.defaultLegacyJSONURL()
    ) {
        self.databaseURL = databaseURL
        self.sessionDatabase = SessionDatabase(databaseURL: databaseURL, legacyJSONURL: legacyJSONURL)
    }

    func load() -> [SessionSnapshot] {
        sessionDatabase.load()
    }

    func save(_ snapshots: [SessionSnapshot]) {
        sessionDatabase.save(snapshots)
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
        try? execute(database, "ALTER TABLE sessions ADD COLUMN agent_session_id TEXT")
        try? execute(database, "ALTER TABLE sessions ADD COLUMN title_url_auto INTEGER NOT NULL DEFAULT 1")
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

}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
