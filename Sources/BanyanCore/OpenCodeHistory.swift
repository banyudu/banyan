import CSQLite
import Foundation

/// Reads OpenCode's SQLite session store for resume matching.
///
/// All opencode-backed Banyan providers (`.opencode`, `.deepseek`, `.hunyuan`,
/// `.muse`, `.qwen`) share one database (`~/.local/share/opencode/opencode.db`,
/// table `session`). A Banyan session that lost its tmux backing (reboot,
/// `tmux kill-server`, park-then-quit) must resume its `ses_…` conversation via
/// `opencode --session <id>` — re-running the launch command always starts a
/// blank new session, which is the "many sessions fall into new session" bug.
///
/// Matching uses only cwd + timestamps (same windows as
/// `AgentSessionMatcher`), never titles or transcript bodies, so it stays cheap
/// even though the database file itself is gigabytes (the `session` table is
/// only ~1k rows; bulk lives in `message`/`part`).
public enum OpenCodeHistory {
    public static func databaseURL(
        homeDirectory: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        if let override = environment["OPENCODE_DB"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        let dataDirectory: String
        if let xdgDataHome = environment["XDG_DATA_HOME"], !xdgDataHome.isEmpty {
            dataDirectory = (xdgDataHome as NSString).expandingTildeInPath
        } else {
            dataDirectory = homeDirectory.appendingPathComponent(".local/share").path
        }
        return URL(fileURLWithPath: dataDirectory)
            .appendingPathComponent("opencode/opencode.db")
    }

    /// Candidates for `cwd`, newest-first, bounded. All returned as `.opencode`
    /// — see `AgentSessionMatcher.providersMatch` for why sub-providers
    /// (`.muse`, `.deepseek`, …) still match them.
    public static func resumeCandidates(
        homeDirectory: URL,
        cwd: String,
        maxFilesScanned: Int = 20_000,
        fileManager: FileManager = .default
    ) -> [AgentResumeCandidate] {
        guard let databaseURL = databaseURL(homeDirectory: homeDirectory),
              fileManager.fileExists(atPath: databaseURL.path),
              let database = openReadOnly(databaseURL)
        else {
            return []
        }
        defer { sqlite3_close(database) }

        // The session table is tiny (~1k rows); pull recent rows and filter by
        // canonical path in Swift so symlink spellings (`/tmp` vs
        // `/private/tmp`) still match, mirroring the codex/claude matchers.
        let limit = max(1, min(maxFilesScanned, 20_000))
        let sql = """
        SELECT id, directory, time_created, time_updated, time_archived
        FROM session
        ORDER BY time_updated DESC
        LIMIT \(limit)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        let normalizedCWD = PathDisplayName.canonicalPath(cwd)
        var candidates: [AgentResumeCandidate] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let sourceID = columnText(statement, 0),
                  sourceID.hasPrefix("ses_"),
                  let directory = columnText(statement, 1),
                  !directory.isEmpty
            else {
                continue
            }
            // Archived sessions are cleanup artifacts, not resume targets.
            // (Upstream `opencode --continue` currently picks them anyway;
            // Banyan must not.)
            if sqlite3_column_type(statement, 4) != SQLITE_NULL {
                continue
            }
            guard PathDisplayName.canonicalPath(directory) == normalizedCWD else {
                continue
            }
            let createdAt = dateFromMillis(sqlite3_column_int64(statement, 2)) ?? .distantPast
            let updatedAt = dateFromMillis(sqlite3_column_int64(statement, 3)) ?? createdAt
            candidates.append(AgentResumeCandidate(
                provider: .opencode,
                sourceID: sourceID,
                cwd: directory,
                createdAt: createdAt,
                updatedAt: updatedAt
            ))
        }
        return candidates
    }

    /// Full import for history UI + live title matching. Bounded like
    /// codex/claude imports; titles come straight from the session row so no
    /// transcript parsing is needed.
    public static func load(
        homeDirectory: URL,
        maxSessions: Int = 10,
        fileManager: FileManager = .default
    ) -> [ImportedAgentSession] {
        guard let databaseURL = databaseURL(homeDirectory: homeDirectory),
              fileManager.fileExists(atPath: databaseURL.path),
              let database = openReadOnly(databaseURL)
        else {
            return []
        }
        defer { sqlite3_close(database) }

        let limit = max(1, min(maxSessions, 500))
        let sql = """
        SELECT id, directory, title, time_created, time_updated
        FROM session
        WHERE time_archived IS NULL
        ORDER BY time_updated DESC
        LIMIT \(limit)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var sessions: [ImportedAgentSession] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let sourceID = columnText(statement, 0),
                  sourceID.hasPrefix("ses_"),
                  let directory = columnText(statement, 1),
                  !directory.isEmpty
            else {
                continue
            }
            let title = columnText(statement, 2)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let createdAt = dateFromMillis(sqlite3_column_int64(statement, 3)) ?? .distantPast
            let updatedAt = dateFromMillis(sqlite3_column_int64(statement, 4)) ?? createdAt
            let displayTitle = (title?.isEmpty == false ? title! : "OpenCode \(sourceID.prefix(8))")
            sessions.append(ImportedAgentSession(
                id: "history-opencode-\(sourceID)",
                provider: .opencode,
                sourceID: sourceID,
                title: displayTitle,
                cwd: directory,
                transcriptURL: databaseURL,
                createdAt: createdAt,
                updatedAt: updatedAt
            ))
        }
        return sessions
    }

    private static func openReadOnly(_ url: URL) -> OpaquePointer? {
        var database: OpaquePointer?
        let uri = "\(url.absoluteString)?mode=ro"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(uri, &database, flags, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            return nil
        }
        return database
    }

    private static func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }

    private static func dateFromMillis(_ millis: Int64) -> Date? {
        guard millis > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(millis) / 1_000)
    }
}
