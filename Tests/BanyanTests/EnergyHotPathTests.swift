import BanyanCore
import Foundation
import Testing
@testable import Banyan

@Test @MainActor func controlSummaryPreservesUTCTimestampsAtSecondPrecision() throws {
    let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
    let store = fixture.makeStore()
    let server = ControlServer(store: store, host: store.host, port: .any)
    let cases: [(TimeInterval, String)] = [
        (-0.1, "1969-12-31T23:59:59Z"),
        (0, "1970-01-01T00:00:00Z"),
        (0.999, "1970-01-01T00:00:00Z"),
        (1_760_000_000.789, "2025-10-09T08:53:20Z")
    ]
    for (timestamp, expected) in cases {
        let session = TerminalSession(
            id: "history", title: "History", cwd: fixture.project.path, command: "codex",
            status: .closed, createdAt: Date(timeIntervalSince1970: timestamp),
            updatedAt: Date(timeIntervalSince1970: timestamp),
            displayContext: SessionDisplayLabel.historicalContext(cwd: fixture.project.path, homeDirectory: fixture.home.path),
            theme: .system, tmuxBackend: banyanTestTmuxBackend,
            telemetry: banyanTestTelemetry, host: store.host
        )
        let summary = server.summary(session)
        #expect(summary["createdAt"] as? String == expected)
        #expect(summary["updatedAt"] as? String == expected)
    }
}

@Test @MainActor func activeSidebarCacheTracksReopenedClosedAndSuspendedRows() throws {
    let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
    let now = Date()
    fixture.persistence.save(["first", "second", "third"].map { id in
        SessionSnapshot(
            id: id, tmuxSessionName: "banyan-\(id)", title: id, reportedTitle: nil,
            isTitlePinned: true, cwd: fixture.project.path, command: "codex", status: .closed,
            tone: .blue, createdAt: now, updatedAt: now
        )
    })
    let store = fixture.makeStore()
    store.loadPersistedSessionsIfNeeded()
    defer { store.flushPendingSessionSaves() }
    store.sortMode = .title
    let first = try #require(store.sessions.first { $0.id == "first" })
    let second = try #require(store.sessions.first { $0.id == "second" })
    let third = try #require(store.sessions.first { $0.id == "third" })
    func sidebarIDs() -> [String] { store.sessionSidebarGroups.flatMap(\.items).map(\.id) }

    #expect(sidebarIDs().isEmpty)
    first.status = .needInput
    second.status = .needInput
    #expect(store.visibleSessions.map(\.id) == ["first", "second"])
    #expect(sidebarIDs() == ["first", "second"])
    // Warm the cache before each membership/order change.
    third.title = "A closed history row"
    third.updatedAt = now.addingTimeInterval(10)
    #expect(sidebarIDs() == ["first", "second"])
    second.title = "A live row"
    #expect(sidebarIDs() == ["second", "first"])
    second.isSuspended = true
    #expect(sidebarIDs() == ["first", "second"])
    first.status = .closed
    #expect(store.visibleSessions.map(\.id) == ["second"])
    #expect(sidebarIDs() == ["second"])
    third.status = .needInput
    #expect(sidebarIDs() == ["third", "second"])
}

@Test @MainActor func navigationMenusIncludeHistoryAndRespectHiddenChildren() throws {
    let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
    let now = Date()
    fixture.persistence.save(["parent", "child", "history"].map { id in
        SessionSnapshot(
            id: id, tmuxSessionName: "banyan-\(id)", title: id, reportedTitle: nil,
            cwd: fixture.project.path, command: "codex", status: .closed, tone: .blue,
            createdAt: now, updatedAt: now
        )
    })
    let store = fixture.makeStore()
    store.loadPersistedSessionsIfNeeded()
    defer { store.flushPendingSessionSaves() }
    let parent = try #require(store.sessions.first { $0.id == "parent" })
    let child = try #require(store.sessions.first { $0.id == "child" })
    let history = try #require(store.sessions.first { $0.id == "history" })

    #expect(!store.hasMultipleSidebarSessions)
    #expect(!store.hasWorkableSession)
    parent.status = .executing
    child.status = .idle
    child.parentSessionID = parent.id
    store.expandedParentIDs = []
    store.collapsedParentIDs = [parent.id]
    #expect(!store.hasMultipleSidebarSessions)
    #expect(!store.hasWorkableSession)
    store.expandedParentIDs = [parent.id]
    #expect(store.hasMultipleSidebarSessions)
    #expect(store.hasWorkableSession)
    child.status = .closed
    #expect(!store.hasMultipleSidebarSessions)
    #expect(!store.hasWorkableSession)
    history.titleURL = "https://tracker.example/issue/TASK-123"
    #expect(store.hasMultipleSidebarSessions)
    #expect(!store.hasWorkableSession)
    parent.status = .closed
    #expect(!store.hasMultipleSidebarSessions)
    child.titleURL = "https://tracker.example/issue/TASK-456"
    #expect(store.hasMultipleSidebarSessions)
    #expect(!store.hasWorkableSession)
}
