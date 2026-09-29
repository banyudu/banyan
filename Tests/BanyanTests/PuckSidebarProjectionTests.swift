@testable import Banyan
@testable import BanyanCore
import Testing

private func puckSummary(id: String, workspace: String) throws -> PuckSessionSummary {
    try PuckSessionSummary([
        "id": id,
        "provider": "codex",
        "account": "personal",
        "workspace": workspace,
        "cwd": workspace,
        "model": "example-model",
        "position": "idle",
    ])
}

@Test func puckSessionAppearsInItsProjectGroup() throws {
    let session = try puckSummary(id: "puck-one", workspace: "/tmp/example")
    let project = PuckSessionProject(id: "path:/tmp/example", title: "example")
    let terminalGroup = SidebarSessionGroup(id: project.id, title: project.title, items: [])

    let projection = PuckSidebarProjection.make(
        terminalGroups: [terminalGroup],
        puckSessions: [session],
        projectsBySessionID: [session.id: project],
        query: ""
    )

    #expect(projection.groups.map(\.id) == [project.id])
    #expect(projection.sessionsByGroup[project.id]?.map(\.id) == [session.id])
}

@Test func puckOnlyProjectGetsSidebarGroupAndSearchResult() throws {
    let session = try puckSummary(id: "puck-only", workspace: "/tmp/other")
    let project = PuckSessionProject(id: "path:/tmp/other", title: "other")
    let history = SidebarSessionGroup(id: "history", title: "History", items: [])

    let grouped = PuckSidebarProjection.make(
        terminalGroups: [history],
        puckSessions: [session],
        projectsBySessionID: [session.id: project],
        query: ""
    )
    #expect(grouped.groups.map(\.id) == [project.id, "history"])
    #expect(grouped.sessionsByGroup[project.id]?.map(\.id) == [session.id])

    let searched = PuckSidebarProjection.make(
        terminalGroups: [],
        puckSessions: [session],
        projectsBySessionID: [session.id: project],
        query: "example-model"
    )
    #expect(searched.groups.map(\.id) == ["search"])
    #expect(searched.sessionsByGroup["search"]?.map(\.id) == [session.id])
}
