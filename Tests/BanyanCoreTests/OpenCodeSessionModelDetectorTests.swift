import CSQLite
import Foundation
import Testing
@testable import BanyanCore

@Test func openCodeModelDetectorReadsNewestSessionRowFromOverrideDatabase() throws {
    let databaseURL = temporaryDatabaseURL()
    defer { try? FileManager.default.removeItem(at: databaseURL) }
    let directory = "/tmp/opencode-project"
    let now = Date()
    try createDatabase(
        at: databaseURL,
        rows: [
            (directory, now.addingTimeInterval(-3_600), now.addingTimeInterval(-3_500), #"{"id":"gpt-4.1","providerID":"openai"}"#),
            (directory, now.addingTimeInterval(-2), now, #"{"id":"deepseek-v4-flash","providerID":"opencode-go"}"#)
        ]
    )

    let identity = OpenCodeSessionModelDetector().resolve(
        directory: directory,
        sessionStartedAt: now.addingTimeInterval(-5),
        environment: ["OPENCODE_DB": databaseURL.path]
    )

    #expect(identity?.modelID == "deepseek-v4-flash")
    #expect(identity?.provider == .deepseek)
    #expect(identity?.isExactModelID == true)
}

@Test func openCodeModelDetectorHonorsXDGDataHome() throws {
    let dataHome = FileManager.default.temporaryDirectory
        .appendingPathComponent("banyan-opencode-xdg-\(UUID().uuidString)", isDirectory: true)
    let databaseURL = dataHome.appendingPathComponent("opencode/opencode.db")
    defer { try? FileManager.default.removeItem(at: dataHome) }
    let now = Date()
    try createDatabase(
        at: databaseURL,
        rows: [("/tmp/project", now, now, #"{"id":"gemini-2.5-pro","providerID":"google"}"#)]
    )

    let identity = OpenCodeSessionModelDetector().resolve(
        directory: "/tmp/project",
        sessionStartedAt: now,
        environment: ["XDG_DATA_HOME": dataHome.path]
    )

    #expect(identity?.modelID == "gemini-2.5-pro")
    #expect(identity?.provider == .gemini)
}

@Test func openCodeStatusBarFallbackOnlyReturnsTheDisplayedModel() {
    let identity = OpenCodeSessionModelDetector.statusBarIdentity(in: """
    ┃  Flash-Med · DeepSeek V4 Flash (2x usage) OpenCode Go
    """)

    #expect(identity?.modelID == "DeepSeek V4 Flash")
    #expect(identity?.provider == .deepseek)
    #expect(identity?.isExactModelID == false)
}

@Test func supervisorUsesOpenCodeRuntimeIdentityAndDropsItWhenTheProcessExits() throws {
    let databaseURL = temporaryDatabaseURL()
    defer { try? FileManager.default.removeItem(at: databaseURL) }
    let directory = "/tmp/opencode-live-project"
    let now = Date()
    try createDatabase(
        at: databaseURL,
        rows: [(directory, now, now, #"{"id":"deepseek-v4-flash","providerID":"opencode-go"}"#)]
    )
    let backend = SupervisorBackend(currentCommand: "opencode", currentPath: directory)
    let supervisor = AgentSupervisor(
        backend: backend,
        processTable: ProcessTable(rows: [
            ProcessInfoRow(
                pid: 101,
                parentPID: 100,
                state: "S",
                elapsed: 1,
                commandName: "/opt/homebrew/bin/opencode",
                arguments: "opencode"
            )
        ])
    )

    let live = supervisor.inspect(
        tmuxSessionName: "banyan-test",
        launchCommand: "opencode",
        currentStatus: .running,
        cwd: directory,
        sessionStartedAt: now,
        environment: ["OPENCODE_DB": databaseURL.path]
    )
    #expect(live?.provider == .deepseek)
    #expect(live?.modelID == "deepseek-v4-flash")
    #expect(live?.modelIDIsExact == true)

    let shellSupervisor = AgentSupervisor(
        backend: SupervisorBackend(currentCommand: "zsh", currentPath: directory),
        processTable: ProcessTable(rows: [])
    )
    let exited = shellSupervisor.inspect(
        tmuxSessionName: "banyan-test",
        launchCommand: "opencode",
        currentStatus: .needInput,
        cwd: directory,
        sessionStartedAt: now,
        environment: ["OPENCODE_DB": databaseURL.path]
    )
    #expect(exited?.provider == nil)
    #expect(exited?.modelID == nil)
}

@Test func supervisorFallsBackToTheOpenCodeStatusBarWhenTheDatabaseIsUnavailable() {
    let directory = "/tmp/opencode-fallback-project"
    let supervisor = AgentSupervisor(
        backend: SupervisorBackend(
            currentCommand: "opencode",
            currentPath: directory,
            visibleText: "┃  Flash-Med · DeepSeek V4 Flash (2x usage) OpenCode Go"
        ),
        processTable: ProcessTable(rows: [
            ProcessInfoRow(
                pid: 101,
                parentPID: 100,
                state: "S",
                elapsed: 1,
                commandName: "/opt/homebrew/bin/opencode",
                arguments: "opencode"
            )
        ])
    )

    let result = supervisor.inspect(
        tmuxSessionName: "banyan-test",
        launchCommand: "opencode",
        currentStatus: .running,
        cwd: directory,
        sessionStartedAt: Date(),
        environment: ["OPENCODE_DB": "/tmp/nonexistent-opencode.db"]
    )

    #expect(result?.provider == .deepseek)
    #expect(result?.modelID == "DeepSeek V4 Flash")
    #expect(result?.modelIDIsExact == false)
}

private func temporaryDatabaseURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("banyan-opencode-\(UUID().uuidString).db")
}

private func createDatabase(
    at url: URL,
    rows: [(directory: String, created: Date, updated: Date, model: String)]
) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
        throw NSError(domain: "OpenCodeSessionModelDetectorTests", code: 1)
    }
    defer { sqlite3_close(database) }
    guard sqlite3_exec(database, "CREATE TABLE session (directory TEXT, time_created INTEGER, time_updated INTEGER, model TEXT)", nil, nil, nil) == SQLITE_OK else {
        throw NSError(domain: "OpenCodeSessionModelDetectorTests", code: 2)
    }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "INSERT INTO session VALUES (?, ?, ?, ?)", -1, &statement, nil) == SQLITE_OK, let statement else {
        throw NSError(domain: "OpenCodeSessionModelDetectorTests", code: 3)
    }
    defer { sqlite3_finalize(statement) }
    for row in rows {
        sqlite3_bind_text(statement, 1, row.directory, -1, sqliteTransient)
        sqlite3_bind_int64(statement, 2, Int64(row.created.timeIntervalSince1970 * 1_000))
        sqlite3_bind_int64(statement, 3, Int64(row.updated.timeIntervalSince1970 * 1_000))
        sqlite3_bind_text(statement, 4, row.model, -1, sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw NSError(domain: "OpenCodeSessionModelDetectorTests", code: 4)
        }
        sqlite3_reset(statement)
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

@Test func openCodeHistoryMatchesByCwdAndCreationWindow() throws {
    // Regression for "recover after park falls into new session": an opencode
    // Banyan session must resolve its ses_… via cwd + timestamps so Recover can
    // run `opencode --session` instead of replaying the launch command.
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("banyan-opencode-history-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let dbDir = home.appendingPathComponent(".local/share/opencode", isDirectory: true)
    try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
    let dbURL = dbDir.appendingPathComponent("opencode.db")
    let directory = "/tmp/opencode-resume-project"
    let now = Date()
    try createHistoryDatabase(
        at: dbURL,
        rows: [
            // Same cwd, created 46s after the Banyan session — the match.
            ("ses_match1234567890123456789012", directory, "Target conversation",
             now.addingTimeInterval(46), now.addingTimeInterval(100)),
            // Same cwd but a day earlier — outside the creation window.
            ("ses_old123456789012345678901234", directory, "Old conversation",
             now.addingTimeInterval(-86_400), now.addingTimeInterval(-85_000)),
        ]
    )

    let candidates = OpenCodeHistory.resumeCandidates(
        homeDirectory: home,
        cwd: directory
    )
    #expect(candidates.count == 2)

    let match = AgentSessionMatcher.bestHistoryResumeMatch(
        sessionCWD: directory,
        sessionCreatedAt: now,
        sessionUpdatedAt: now.addingTimeInterval(120),
        sessionResetAt: nil,
        provider: .opencode,
        in: candidates
    )
    #expect(match?.sourceID == "ses_match1234567890123456789012")
}

@Test func openCodeProvidersMatchAcrossSubProviders() {
    // Restored `opencode --agent …` rows report as generic `.opencode` while
    // live/model identity may refine to `.muse`/`.deepseek`/…. They share one
    // SQLite store, so matching must treat the family as equivalent.
    #expect(AgentSessionMatcher.providersMatch(sessionProvider: .opencode, candidateProvider: .opencode))
    #expect(AgentSessionMatcher.providersMatch(sessionProvider: .muse, candidateProvider: .opencode))
    #expect(AgentSessionMatcher.providersMatch(sessionProvider: .opencode, candidateProvider: .muse))
    #expect(AgentSessionMatcher.providersMatch(sessionProvider: .deepseek, candidateProvider: .qwen))
    #expect(!AgentSessionMatcher.providersMatch(sessionProvider: .codex, candidateProvider: .opencode))
    #expect(!AgentSessionMatcher.providersMatch(sessionProvider: .opencode, candidateProvider: .claude))
    #expect(AgentSessionMatcher.participatesInLiveAgentMatch(
        isImportedHistory: false, status: .running, provider: .opencode
    ))
    #expect(AgentSessionMatcher.participatesInLiveAgentMatch(
        isImportedHistory: false, status: .needInput, provider: .muse
    ))
}

private func createHistoryDatabase(
    at url: URL,
    rows: [(id: String, directory: String, title: String, created: Date, updated: Date)]
) throws {
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
        throw NSError(domain: "OpenCodeHistoryTests", code: 1)
    }
    defer { sqlite3_close(database) }
    guard sqlite3_exec(database, """
        CREATE TABLE session (
            id TEXT PRIMARY KEY,
            directory TEXT NOT NULL,
            title TEXT NOT NULL,
            time_created INTEGER NOT NULL,
            time_updated INTEGER NOT NULL,
            time_archived INTEGER
        )
        """, nil, nil, nil) == SQLITE_OK else {
        throw NSError(domain: "OpenCodeHistoryTests", code: 2)
    }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database,
        "INSERT INTO session (id, directory, title, time_created, time_updated) VALUES (?, ?, ?, ?, ?)",
        -1, &statement, nil) == SQLITE_OK, let statement else {
        throw NSError(domain: "OpenCodeHistoryTests", code: 3)
    }
    defer { sqlite3_finalize(statement) }
    for row in rows {
        sqlite3_bind_text(statement, 1, row.id, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, row.directory, -1, sqliteTransient)
        sqlite3_bind_text(statement, 3, row.title, -1, sqliteTransient)
        sqlite3_bind_int64(statement, 4, Int64(row.created.timeIntervalSince1970 * 1_000))
        sqlite3_bind_int64(statement, 5, Int64(row.updated.timeIntervalSince1970 * 1_000))
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw NSError(domain: "OpenCodeHistoryTests", code: 4)
        }
        sqlite3_reset(statement)
    }
}

private struct SupervisorBackend: AgentSupervisorBackend {
    let currentCommand: String
    let currentPath: String
    var visibleText = ""

    func hasSession(named name: String) -> Bool { true }

    func primaryPaneSnapshot(named name: String) -> TmuxPaneSnapshot? {
        TmuxPaneSnapshot(
            paneID: "%1",
            rootPID: 100,
            currentCommand: currentCommand,
            currentPath: currentPath,
            isDead: false,
            isInMode: false
        )
    }

    func captureVisibleText(paneID: String, lineLimit: Int) -> String { visibleText }
}
