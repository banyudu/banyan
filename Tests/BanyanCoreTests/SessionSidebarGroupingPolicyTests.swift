import Testing
@testable import BanyanCore

private func sidebarCandidate(
    _ id: String,
    groupID: String,
    title: String,
    parent: String? = nil
) -> SessionSidebarCandidate {
    SessionSidebarCandidate(
        id: id,
        groupID: groupID,
        groupTitle: title,
        parentSessionID: parent
    )
}

@Test func sidebarGroupingOrdersGroupsByTitleAndKeepsHierarchyRows() {
    let groups = SessionSidebarGroupingPolicy.groups(for: [
        sidebarCandidate("z-child", groupID: "z", title: "Zulu", parent: "z-root"),
        sidebarCandidate("z-root", groupID: "z", title: "Zulu"),
        sidebarCandidate("a-root", groupID: "a", title: "Alpha")
    ])

    #expect(groups.map(\.id) == ["a", "z"])
    #expect(groups[1].rows == [
        SessionSidebarRow(id: "z-root", depth: 0),
        SessionSidebarRow(id: "z-child", depth: 1)
    ])
}

@Test func sidebarGroupingUsesGroupIDAsTieBreaker() {
    let groups = SessionSidebarGroupingPolicy.groups(for: [
        sidebarCandidate("second", groupID: "b", title: "Same"),
        sidebarCandidate("first", groupID: "a", title: "Same")
    ])

    #expect(groups.map(\.id) == ["a", "b"])
}
