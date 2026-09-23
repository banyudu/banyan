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

@Test func sessionDatabasePrunesOnlyClosedRowsPastTheRetentionWindow() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("banyan-session-db-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let database = SessionDatabase(
        databaseURL: directory.appendingPathComponent("state.sqlite"),
        legacyJSONURL: directory.appendingPathComponent("sessions.json")
    )
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    database.save([
        retentionSnapshot(id: "ancient", status: .closed, updatedAt: now, ageDays: 400, in: directory),
        retentionSnapshot(id: "recent", status: .closed, updatedAt: now, ageDays: 3, in: directory),
        retentionSnapshot(id: "live", status: .executing, updatedAt: now, ageDays: 400, in: directory),
        retentionSnapshot(id: "held-parent", status: .closed, updatedAt: now, ageDays: 400, in: directory),
        retentionSnapshot(
            id: "held-child",
            status: .needInput,
            updatedAt: now,
            ageDays: 400,
            parentSessionID: "held-parent",
            in: directory
        )
    ])

    #expect(database.pruneExpiredSessions(retentionDays: 30, now: now) == 1)
    #expect(database.load().map(\.id) == ["recent", "live", "held-parent", "held-child"])

    // Idempotent: a second sweep over the same window has nothing left to do.
    #expect(database.pruneExpiredSessions(retentionDays: 30, now: now) == 0)
}

@Test func sessionDatabasePruneSparesTheStoredSelectedSession() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("banyan-session-db-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let database = SessionDatabase(
        databaseURL: directory.appendingPathComponent("state.sqlite"),
        legacyJSONURL: directory.appendingPathComponent("sessions.json")
    )
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    database.save([
        retentionSnapshot(id: "selected", status: .closed, updatedAt: now, ageDays: 400, in: directory),
        retentionSnapshot(id: "other", status: .closed, updatedAt: now, ageDays: 400, in: directory)
    ])
    // The prune also runs with no app attached, so the guard reads the selection
    // out of `workspace_state` rather than out of a live store.
    database.saveState(["selectedSessionID": "selected"])

    #expect(database.pruneExpiredSessions(retentionDays: 30, now: now) == 1)
    #expect(database.load().map(\.id) == ["selected"])
}

@Test func sessionDatabaseRetentionOffAndSaveItselfNeverPrune() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("banyan-session-db-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let database = SessionDatabase(
        databaseURL: directory.appendingPathComponent("state.sqlite"),
        legacyJSONURL: directory.appendingPathComponent("sessions.json")
    )
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let ancient = [
        retentionSnapshot(id: "ancient", status: .closed, updatedAt: now, ageDays: 4000, in: directory)
    ]
    database.save(ancient)

    #expect(database.pruneExpiredSessions(retentionDays: 0, now: now) == 0)
    #expect(database.load().map(\.id) == ["ancient"])

    // The supervisor calls `save` on every tick; retention must never ride along
    // with it, or the normal persistence path becomes a full-table sweep.
    database.save(ancient)
    #expect(database.load().map(\.id) == ["ancient"])
}

private func retentionSnapshot(
    id: String,
    status: SessionStatus,
    updatedAt now: Date,
    ageDays: Double,
    parentSessionID: String? = nil,
    in directory: URL
) -> SessionSnapshot {
    let updatedAt = now.addingTimeInterval(-ageDays * 24 * 60 * 60)
    return SessionSnapshot(
        id: id,
        tmuxSessionName: "banyan-\(id)",
        title: id,
        reportedTitle: nil,
        cwd: directory.path,
        command: "codex",
        status: status,
        tone: .blue,
        parentSessionID: parentSessionID,
        createdAt: updatedAt,
        updatedAt: updatedAt
    )
}
