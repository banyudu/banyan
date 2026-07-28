import Foundation
import Testing
@testable import BanyanCore

@Test func sessionListModelAcceptsAlternateDataSource() {
    let dataSource = AlternateDataSource()
    var model = SessionListModel(dataSource: dataSource)

    model.reload()

    #expect(model.sessions.map(\.id) == ["alternate"])
}

private struct AlternateDataSource: SessionListDataSource {
    func loadActiveSessions() -> [SessionSnapshot] {
        let now = Date(timeIntervalSince1970: 100)
        return [SessionSnapshot(
            id: "alternate",
            tmuxSessionName: "banyan-alternate",
            title: "Alternate",
            reportedTitle: nil,
            cwd: "/tmp",
            command: "",
            status: .running,
            tone: .blue,
            createdAt: now,
            updatedAt: now
        )]
    }

    func loadHistory(limit: Int) -> [ImportedAgentSession] { [] }
}
