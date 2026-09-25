import CSQLite
import Foundation
import Testing
@testable import BanyanCore

@Test func sessionDatabaseRoundTripsPortableSnapshots() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("banyan-session-db-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let database = SessionDatabase(
        databaseURL: directory.appendingPathComponent("state.sqlite"),
        legacyJSONURL: directory.appendingPathComponent("sessions.json")
    )
    let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    let snapshot = SessionSnapshot(
        id: "ENG-123",
        tmuxSessionName: "banyan-ENG-123",
        title: "Build the TUI",
        titleURL: "https://linear.app/example/issue/ENG-123",
        titleURLWasAutoDetected: false,
        reportedTitle: "Build the TUI",
        generatedTitle: nil,
        isTitlePinned: true,
        cwd: directory.path,
        command: "codex",
        status: .running,
        tone: .blue,
        createdAt: createdAt,
        updatedAt: createdAt
    )

    database.save([snapshot])
    database.saveState([
        "selectedSessionID": snapshot.id,
        "terminalFontSize": "13"
    ])

    #expect(database.load() == [snapshot])
    #expect(database.loadState() == [
        "selectedSessionID": snapshot.id,
        "terminalFontSize": "13"
    ])
}

@Test func sessionDatabaseRoundTripsSuspensionWithoutTouchingStatus() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("banyan-session-db-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let database = SessionDatabase(
        databaseURL: directory.appendingPathComponent("state.sqlite"),
        legacyJSONURL: directory.appendingPathComponent("sessions.json")
    )
    let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    func snapshot(id: String, status: SessionStatus, isSuspended: Bool) -> SessionSnapshot {
        SessionSnapshot(
            id: id,
            tmuxSessionName: "banyan-\(id)",
            title: id,
            reportedTitle: nil,
            cwd: directory.path,
            command: "codex",
            status: status,
            tone: .blue,
            isSuspended: isSuspended,
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }

    // A parked session keeps the agent state it had when it was parked; that is
    // the whole reason suspension is a flag rather than a `SessionStatus` case.
    let parked = snapshot(id: "parked", status: .executing, isSuspended: true)
    let live = snapshot(id: "live", status: .executing, isSuspended: false)
    database.save([parked, live])

    let loaded = database.load()
    #expect(loaded == [parked, live])
    #expect(loaded.first?.isSuspended == true)
    #expect(loaded.first?.status == .executing)
    #expect(loaded.last?.isSuspended == false)

    // Resuming clears the flag in place without disturbing the observed status.
    database.save([parked.updating(isSuspended: false, updatedAt: createdAt), live])
    #expect(database.load().first?.isSuspended == false)
    #expect(database.load().first?.status == .executing)
}

@Test func savingOneSessionPreservesOtherHistoryRowsAndOrdering() {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("banyan-session-delta-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = SessionDatabase(
        databaseURL: directory.appendingPathComponent("state.sqlite"),
        legacyJSONURL: directory.appendingPathComponent("sessions.json")
    )
    let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    func snapshot(_ id: String, title: String) -> SessionSnapshot {
        SessionSnapshot(
            id: id,
            tmuxSessionName: nil,
            title: title,
            reportedTitle: nil,
            cwd: "/Users/example/dev/my-project",
            command: "codex",
            status: .closed,
            tone: .blue,
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }
    let old = snapshot("old", title: "Old history")
    let live = snapshot("live", title: "First title")
    database.save([old, live])

    let renamed = snapshot("live", title: "Updated title")
    database.saveSession(renamed, sortOrder: 1)
    #expect(database.load() == [old, renamed])
}

@Test func sessionDatabaseDefaultsSuspensionOffForRowsWrittenBeforeTheColumnExisted() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("banyan-session-db-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseURL = directory.appendingPathComponent("state.sqlite")

    // Write through a database whose `sessions` table predates `is_suspended`,
    // then reopen: the additive migration has to backfill rather than drop rows.
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try legacySessionsTable(at: databaseURL)

    let snapshots = SessionDatabase(
        databaseURL: databaseURL,
        legacyJSONURL: directory.appendingPathComponent("sessions.json")
    ).load()

    #expect(snapshots.count == 1)
    #expect(snapshots.first?.id == "legacy")
    #expect(snapshots.first?.isSuspended == false)
}


/// Creates a `sessions` table in the shape Banyan wrote before suspension existed,
/// with one row in it.
private func legacySessionsTable(at url: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
        throw NSError(domain: "BanyanSQLiteTest", code: 1)
    }
    defer { sqlite3_close(database) }

    for sql in [
        """
        CREATE TABLE sessions (
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
            sort_order INTEGER NOT NULL DEFAULT 0,
            agent_session_id TEXT,
            title_url_auto INTEGER NOT NULL DEFAULT 1
        )
        """,
        """
        INSERT INTO sessions (id, title, cwd, command, status, tone, created_at, updated_at)
        VALUES ('legacy', 'Legacy', '/tmp', 'codex', 'executing', 'blue',
                '2023-11-14T22:13:20.000Z', '2023-11-14T22:13:20.000Z')
        """
    ] {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "BanyanSQLiteTest", code: 2)
        }
    }
}
