import Foundation
import Testing
@testable import BanyanCore

@Test func sessionDataSourceSynchronizesAndFiltersPersistedRows() {
    let now = Date(timeIntervalSince1970: 100)
    let persistence = InMemorySessionPersistence(snapshots: [
        SessionSnapshot(
            id: "live",
            tmuxSessionName: "banyan-live",
            title: "Shell",
            reportedTitle: nil,
            cwd: "/tmp",
            command: "",
            status: .needInput,
            tone: .yellow,
            createdAt: now,
            updatedAt: now
        ),
        SessionSnapshot(
            id: "closed",
            tmuxSessionName: "banyan-closed",
            title: "Closed",
            reportedTitle: nil,
            cwd: "/tmp",
            command: "",
            status: .closed,
            tone: .neutral,
            createdAt: now,
            updatedAt: now
        )
    ])
    let backend = DataSourceTestBackend()
    let dataSource = SessionDataSource(
        persistence: persistence,
        backend: backend,
        processTable: { ProcessTable(rows: []) }
    )

    let active = dataSource.loadActiveSessions()

    #expect(active.map(\.id) == ["live"])
    #expect(persistence.snapshots.first?.status == .running)
}

@Test func sessionDataSourceUsesInjectedHistoryLoader() {
    let dataSource = SessionDataSource(
        persistence: InMemorySessionPersistence(snapshots: []),
        backend: DataSourceTestBackend(),
        historyLoader: { limit in
            #expect(limit == 2)
            return []
        }
    )

    #expect(dataSource.loadHistory(limit: 2).isEmpty)
}

private final class InMemorySessionPersistence: SessionPersistenceBackend, @unchecked Sendable {
    var snapshots: [SessionSnapshot]

    init(snapshots: [SessionSnapshot]) {
        self.snapshots = snapshots
    }

    func load() -> [SessionSnapshot] { snapshots }
    func save(_ snapshots: [SessionSnapshot]) { self.snapshots = snapshots }
}

private final class DataSourceTestBackend: AgentSupervisorBackend, @unchecked Sendable {
    func hasSession(named name: String) -> Bool { name == "banyan-live" }

    func primaryPaneSnapshot(named name: String) -> TmuxPaneSnapshot? {
        guard name == "banyan-live" else { return nil }
        return TmuxPaneSnapshot(
            paneID: "%0",
            rootPID: 100,
            currentCommand: "bash",
            currentPath: "/tmp",
            isDead: false,
            isInMode: false
        )
    }

    func captureVisibleText(paneID: String, lineLimit: Int) -> String { "" }
}
