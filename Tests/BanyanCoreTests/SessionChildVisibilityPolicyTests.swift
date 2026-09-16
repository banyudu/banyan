import Testing
@testable import BanyanCore

private func visibilityItem(
    _ id: String,
    parent: String? = nil,
    status: SessionStatus = .running,
    suspended: Bool = false
) -> SessionChildVisibilityItem {
    SessionChildVisibilityItem(id: id, parentSessionID: parent, status: status, isSuspended: suspended)
}

private func hierarchyRow(_ id: String, depth: Int) -> SessionSidebarRow {
    SessionSidebarRow(id: id, depth: depth)
}

@Test func collapsedParentHidesParkedChildrenButCountsThem() {
    let rows = [
        hierarchyRow("parent", depth: 0),
        hierarchyRow("parked-a", depth: 1),
        hierarchyRow("parked-b", depth: 1),
    ]
    let items: [String: SessionChildVisibilityItem] = [
        "parent": visibilityItem("parent"),
        // Parked need-input never peeks: its status is frozen while suspended.
        "parked-a": visibilityItem("parked-a", parent: "parent", status: .needInput, suspended: true),
        "parked-b": visibilityItem("parked-b", parent: "parent", status: .asking, suspended: true),
    ]
    let (visible, counts) = SessionChildVisibilityPolicy.visibleRows(
        rows: rows,
        itemsByID: items,
        collapsedParentIDs: ["parent"],
        showFinishedChildren: false
    )
    #expect(visible.map(\.id) == ["parent"])
    #expect(counts == ["parent": 2])
}

@Test func collapsedParentStillRevealsLiveChildrenNeedingAttention() {
    let rows = [
        hierarchyRow("parent", depth: 0),
        hierarchyRow("blocked", depth: 1),
        hierarchyRow("quiet", depth: 1),
    ]
    let items: [String: SessionChildVisibilityItem] = [
        "parent": visibilityItem("parent"),
        "blocked": visibilityItem("blocked", parent: "parent", status: .needInput),
        "quiet": visibilityItem("quiet", parent: "parent", status: .idle),
    ]
    let (visible, counts) = SessionChildVisibilityPolicy.visibleRows(
        rows: rows,
        itemsByID: items,
        collapsedParentIDs: ["parent"],
        showFinishedChildren: false
    )
    #expect(visible.map(\.id) == ["parent", "blocked"])
    #expect(counts == ["parent": 1])
}

@Test func finishedChildrenHideUnderExpandedParentsUntilToggled() {
    let rows = [
        hierarchyRow("parent", depth: 0),
        hierarchyRow("done", depth: 1),
        hierarchyRow("failed", depth: 1),
    ]
    let items: [String: SessionChildVisibilityItem] = [
        "parent": visibilityItem("parent"),
        "done": visibilityItem("done", parent: "parent", status: .completed),
        // Failed needs a human decision, so it is never finished-hidden.
        "failed": visibilityItem("failed", parent: "parent", status: .failed),
    ]
    let (hidden, hiddenCounts) = SessionChildVisibilityPolicy.visibleRows(
        rows: rows,
        itemsByID: items,
        collapsedParentIDs: [],
        showFinishedChildren: false
    )
    #expect(hidden.map(\.id) == ["parent", "failed"])
    #expect(hiddenCounts == ["parent": 1])

    let (shown, shownCounts) = SessionChildVisibilityPolicy.visibleRows(
        rows: rows,
        itemsByID: items,
        collapsedParentIDs: [],
        showFinishedChildren: true
    )
    #expect(shown.map(\.id) == ["parent", "done", "failed"])
    #expect(shownCounts == [:])
}

@Test func selectedChildAndItsAncestorsStayVisible() {
    let rows = [
        hierarchyRow("parent", depth: 0),
        hierarchyRow("done", depth: 1),
    ]
    let items: [String: SessionChildVisibilityItem] = [
        "parent": visibilityItem("parent"),
        "done": visibilityItem("done", parent: "parent", status: .completed),
    ]
    let (visible, counts) = SessionChildVisibilityPolicy.visibleRows(
        rows: rows,
        itemsByID: items,
        collapsedParentIDs: ["parent"],
        showFinishedChildren: false,
        selectedID: "done"
    )
    #expect(visible.map(\.id) == ["parent", "done"])
    #expect(counts == [:])
}

@Test func topLevelSessionsAreNeverHidden() {
    let rows = [hierarchyRow("done-root", depth: 0)]
    let items = ["done-root": visibilityItem("done-root", status: .completed)]
    let (visible, _) = SessionChildVisibilityPolicy.visibleRows(
        rows: rows,
        itemsByID: items,
        collapsedParentIDs: [],
        showFinishedChildren: false
    )
    #expect(visible.map(\.id) == ["done-root"])
}

@Test func parentsWithOnlyFinishedOrParkedDescendantsStartCollapsed() {
    let items = [
        visibilityItem("live-parent", status: .running),
        visibilityItem("worker", parent: "live-parent", status: .executing),
        visibilityItem("done-parent", status: .running),
        visibilityItem("done-child", parent: "done-parent", status: .completed),
        visibilityItem("parked-parent", status: .running),
        visibilityItem("parked-child", parent: "parked-parent", status: .needInput, suspended: true),
    ]
    let auto = SessionChildVisibilityPolicy.autoCollapsedParents(in: items)
    #expect(!auto.contains("live-parent"))
    #expect(auto.contains("done-parent"))
    #expect(auto.contains("parked-parent"))
}

@Test func autoCollapseSkipsTheSelectedAncestry() {
    let items = [
        visibilityItem("parent", status: .running),
        visibilityItem("done-child", parent: "parent", status: .completed),
    ]
    #expect(SessionChildVisibilityPolicy.autoCollapsedParents(in: items, selectedID: "done-child") == [])
}
