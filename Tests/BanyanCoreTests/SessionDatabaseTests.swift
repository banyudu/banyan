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
