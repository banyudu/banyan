import Testing
@testable import BanyanCore

private func visibilityItem(
    _ id: String,
    parent: String? = nil,
    status: SessionStatus = .running,
    suspended: Bool = false,
    focus: SessionFocusLane? = nil
) -> SessionChildVisibilityItem {
    SessionChildVisibilityItem(id: id, parentSessionID: parent, status: status, isSuspended: suspended, focusLane: focus)
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

@Test(arguments: [SessionStatus.asking, .needInput, .failed, .idle, .running, .completed])
func collapsedParentHidesAllDescendantsUntilExpanded(status: SessionStatus) {
    let rows = [
        hierarchyRow("parent", depth: 0),
        hierarchyRow("child", depth: 1),
        hierarchyRow("grandchild", depth: 2),
        hierarchyRow("quiet", depth: 1),
        hierarchyRow("other-parent", depth: 0),
    ]
    let items: [String: SessionChildVisibilityItem] = [
        "parent": visibilityItem("parent"),
        "child": visibilityItem("child", parent: "parent", status: status),
        "grandchild": visibilityItem("grandchild", parent: "child", status: .asking),
        "quiet": visibilityItem("quiet", parent: "parent", status: .idle),
        "other-parent": visibilityItem("other-parent"),
    ]
    let (visible, counts) = SessionChildVisibilityPolicy.visibleRows(
        rows: rows,
        itemsByID: items,
        collapsedParentIDs: ["parent"],
        showFinishedChildren: true
    )
    #expect(visible.map(\.id) == ["parent", "other-parent"])
    #expect(counts == ["parent": 3])

    let (expanded, expandedCounts) = SessionChildVisibilityPolicy.visibleRows(
        rows: rows,
        itemsByID: items,
        collapsedParentIDs: [],
        showFinishedChildren: true
    )
    #expect(expanded == rows)
    #expect(expandedCounts == [:])
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

@Test func selectedChildAndItsAncestorsOnlyStayVisibleWhenExpanded() {
    let rows = [
        hierarchyRow("parent", depth: 0),
        hierarchyRow("done-parent", depth: 1),
        hierarchyRow("done", depth: 2),
    ]
    let items: [String: SessionChildVisibilityItem] = [
        "parent": visibilityItem("parent"),
        "done-parent": visibilityItem("done-parent", parent: "parent", status: .completed),
        "done": visibilityItem("done", parent: "done-parent", status: .completed),
    ]
    let (visible, counts) = SessionChildVisibilityPolicy.visibleRows(
        rows: rows,
        itemsByID: items,
        collapsedParentIDs: ["parent"],
        showFinishedChildren: false,
        selectedID: "done"
    )
    #expect(visible.map(\.id) == ["parent"])
    #expect(counts == ["parent": 2])

    let (expanded, expandedCounts) = SessionChildVisibilityPolicy.visibleRows(
        rows: rows,
        itemsByID: items,
        collapsedParentIDs: [],
        showFinishedChildren: false,
        selectedID: "done"
    )
    #expect(expanded == rows)
    #expect(expandedCounts == [:])
}

@Test func topLevelSessionsRemainVisibleInAllScope() {
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

@Test func focusHidesQuietManagedWorkButKeepsAttentionAndUnmanagedSessions() {
    let rows = [hierarchyRow("active", depth: 0), hierarchyRow("quiet", depth: 0),
                hierarchyRow("settled", depth: 0), hierarchyRow("unmanaged", depth: 0)]
    let items: [String: SessionChildVisibilityItem] = [
        "active": visibilityItem("active", focus: .act),
        "quiet": visibilityItem("quiet", focus: .watch),
        "settled": visibilityItem("settled", status: .completed, focus: .settled),
        "unmanaged": visibilityItem("unmanaged"),
    ]

    let (focused, counts) = SessionChildVisibilityPolicy.visibleRows(
        rows: rows, itemsByID: items, collapsedParentIDs: [], showFinishedChildren: false, scope: .focus)
    #expect(focused.map(\.id) == ["active", "unmanaged"])
    #expect(counts == [:])

    let (all, _) = SessionChildVisibilityPolicy.visibleRows(
        rows: rows, itemsByID: items, collapsedParentIDs: [], showFinishedChildren: true, scope: .all)
    #expect(all == rows)
}

@Test func focusPinsAncestorsOfActionableAndUnmanagedChildren() {
    let rows = [hierarchyRow("quiet-parent", depth: 0), hierarchyRow("active", depth: 1),
                hierarchyRow("plain-parent", depth: 0), hierarchyRow("unmanaged", depth: 1)]
    let items: [String: SessionChildVisibilityItem] = [
        "quiet-parent": visibilityItem("quiet-parent", focus: .watch),
        "active": visibilityItem("active", parent: "quiet-parent", focus: .act),
        "plain-parent": visibilityItem("plain-parent", focus: .settled),
        "unmanaged": visibilityItem("unmanaged", parent: "plain-parent"),
    ]
    let (visible, counts) = SessionChildVisibilityPolicy.visibleRows(
        rows: rows, itemsByID: items, collapsedParentIDs: [], showFinishedChildren: false, scope: .focus)
    #expect(visible == rows)
    #expect(counts == [:])
}

@Test func focusIncludesSelectedQuietWorkAndItsAncestors() {
    let rows = [hierarchyRow("umbrella", depth: 0), hierarchyRow("quiet", depth: 1)]
    let items: [String: SessionChildVisibilityItem] = [
        "umbrella": visibilityItem("umbrella", focus: .settled),
        "quiet": visibilityItem("quiet", parent: "umbrella", focus: .watch),
    ]
    let (visible, _) = SessionChildVisibilityPolicy.visibleRows(
        rows: rows, itemsByID: items, collapsedParentIDs: [], showFinishedChildren: false,
        selectedID: "quiet", scope: .focus)
    #expect(visible == rows)
}
