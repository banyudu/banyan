import Testing
@testable import BanyanCore

private func sidebarItem(_ id: String, parent: String? = nil) -> SessionSelectionItem {
    SessionSelectionItem(id: id, parentSessionID: parent)
}

@Test func sidebarHierarchyPlacesChildrenImmediatelyAfterTheirParent() {
    let rows = SessionSidebarHierarchyPolicy.rows(for: [
        sidebarItem("root"),
        sidebarItem("child", parent: "root"),
        sidebarItem("grandchild", parent: "child"),
        sidebarItem("second-root")
    ])

    #expect(rows == [
        SessionSidebarRow(id: "root", depth: 0),
        SessionSidebarRow(id: "child", depth: 1),
        SessionSidebarRow(id: "grandchild", depth: 2),
        SessionSidebarRow(id: "second-root", depth: 0)
    ])
}

@Test func sidebarHierarchyPromotesOrphansAndBreaksCyclesToTopLevel() {
    let rows = SessionSidebarHierarchyPolicy.rows(for: [
        sidebarItem("orphan", parent: "missing"),
        sidebarItem("cycle-a", parent: "cycle-b"),
        sidebarItem("cycle-b", parent: "cycle-a")
    ])

    #expect(rows == [
        SessionSidebarRow(id: "orphan", depth: 0),
        SessionSidebarRow(id: "cycle-a", depth: 0),
        SessionSidebarRow(id: "cycle-b", depth: 1)
    ])
}

@Test func sidebarHierarchyDoesNotRepeatDuplicateIDs() {
    let rows = SessionSidebarHierarchyPolicy.rows(for: [
        sidebarItem("same"),
        sidebarItem("same"),
        sidebarItem("child", parent: "same")
    ])

    #expect(rows == [
        SessionSidebarRow(id: "same", depth: 0),
        SessionSidebarRow(id: "child", depth: 1)
    ])
}
