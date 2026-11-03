import Testing
@testable import BanyanCore

private func visibilityItem(
    _ id: String,
    parent: String? = nil,
    focus: SessionFocusLane? = nil
) -> SessionChildVisibilityItem {
    SessionChildVisibilityItem(id: id, parentSessionID: parent, focusLane: focus)
}

private func hierarchyRow(_ id: String, depth: Int) -> SessionSidebarRow {
    SessionSidebarRow(id: id, depth: depth)
}

@Test func foldedParentHidesAllDescendantsUntilUnfolded() {
    let rows = [
        hierarchyRow("parent", depth: 0),
        hierarchyRow("child", depth: 1),
        hierarchyRow("grandchild", depth: 2),
        hierarchyRow("other-parent", depth: 0),
    ]
    let items: [String: SessionChildVisibilityItem] = [
        "parent": visibilityItem("parent"),
        "child": visibilityItem("child", parent: "parent"),
        "grandchild": visibilityItem("grandchild", parent: "child"),
        "other-parent": visibilityItem("other-parent"),
    ]

    let folded = SessionChildVisibilityPolicy.visibleRows(
        rows: rows,
        itemsByID: items,
        foldedParentIDs: ["parent"]
    )
    #expect(folded.map(\.id) == ["parent", "other-parent"])

    let unfolded = SessionChildVisibilityPolicy.visibleRows(
        rows: rows,
        itemsByID: items,
        foldedParentIDs: []
    )
    #expect(unfolded == rows)
}

@Test func unfoldedParentShowsEveryChild() {
    let rows = [
        hierarchyRow("parent", depth: 0),
        hierarchyRow("running", depth: 1),
        hierarchyRow("completed", depth: 1),
        hierarchyRow("failed", depth: 1),
        hierarchyRow("parked", depth: 1),
    ]
    let items: [String: SessionChildVisibilityItem] = [
        "parent": visibilityItem("parent"),
        "running": visibilityItem("running", parent: "parent"),
        "completed": visibilityItem("completed", parent: "parent"),
        "failed": visibilityItem("failed", parent: "parent"),
        "parked": visibilityItem("parked", parent: "parent"),
    ]

    let visible = SessionChildVisibilityPolicy.visibleRows(
        rows: rows,
        itemsByID: items,
        foldedParentIDs: []
    )
    #expect(visible == rows)
}

@Test func foldingOneBranchDoesNotHideSiblings() {
    let rows = [
        hierarchyRow("parent", depth: 0),
        hierarchyRow("branch", depth: 1),
        hierarchyRow("branch-child", depth: 2),
        hierarchyRow("sibling", depth: 1),
    ]
    let items: [String: SessionChildVisibilityItem] = [
        "parent": visibilityItem("parent"),
        "branch": visibilityItem("branch", parent: "parent"),
        "branch-child": visibilityItem("branch-child", parent: "branch"),
        "sibling": visibilityItem("sibling", parent: "parent"),
    ]

    let visible = SessionChildVisibilityPolicy.visibleRows(
        rows: rows,
        itemsByID: items,
        foldedParentIDs: ["branch"]
    )
    #expect(visible.map(\.id) == ["parent", "branch", "sibling"])
}

@Test func selectedChildStaysHiddenWhileAncestorIsFolded() {
    let rows = [
        hierarchyRow("parent", depth: 0),
        hierarchyRow("child", depth: 1),
    ]
    let items: [String: SessionChildVisibilityItem] = [
        "parent": visibilityItem("parent"),
        "child": visibilityItem("child", parent: "parent"),
    ]

    let folded = SessionChildVisibilityPolicy.visibleRows(
        rows: rows,
        itemsByID: items,
        foldedParentIDs: ["parent"],
        selectedID: "child"
    )
    #expect(folded.map(\.id) == ["parent"])

    let unfolded = SessionChildVisibilityPolicy.visibleRows(
        rows: rows,
        itemsByID: items,
        foldedParentIDs: [],
        selectedID: "child"
    )
    #expect(unfolded == rows)
}

@Test func topLevelCompletedRowsRemainVisible() {
    let rows = [hierarchyRow("done-root", depth: 0)]
    let items = ["done-root": visibilityItem("done-root")]
    let visible = SessionChildVisibilityPolicy.visibleRows(
        rows: rows,
        itemsByID: items,
        foldedParentIDs: []
    )
    #expect(visible.map(\.id) == ["done-root"])
}

@Test func focusHidesQuietManagedWorkButKeepsAttentionAndUnmanagedSessions() {
    let rows = [hierarchyRow("active", depth: 0), hierarchyRow("quiet", depth: 0),
                hierarchyRow("settled", depth: 0), hierarchyRow("unmanaged", depth: 0)]
    let items: [String: SessionChildVisibilityItem] = [
        "active": visibilityItem("active", focus: .act),
        "quiet": visibilityItem("quiet", focus: .watch),
        "settled": visibilityItem("settled", focus: .settled),
        "unmanaged": visibilityItem("unmanaged"),
    ]

    let focused = SessionChildVisibilityPolicy.visibleRows(
        rows: rows, itemsByID: items, foldedParentIDs: [], scope: .focus)
    #expect(focused.map(\.id) == ["active", "unmanaged"])

    let all = SessionChildVisibilityPolicy.visibleRows(
        rows: rows, itemsByID: items, foldedParentIDs: [], scope: .all)
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
    let visible = SessionChildVisibilityPolicy.visibleRows(
        rows: rows, itemsByID: items, foldedParentIDs: [], scope: .focus)
    #expect(visible == rows)
}

@Test func focusIncludesSelectedQuietWorkAndItsAncestors() {
    let rows = [hierarchyRow("umbrella", depth: 0), hierarchyRow("quiet", depth: 1)]
    let items: [String: SessionChildVisibilityItem] = [
        "umbrella": visibilityItem("umbrella", focus: .settled),
        "quiet": visibilityItem("quiet", parent: "umbrella", focus: .watch),
    ]
    let visible = SessionChildVisibilityPolicy.visibleRows(
        rows: rows, itemsByID: items, foldedParentIDs: [],
        selectedID: "quiet", scope: .focus)
    #expect(visible == rows)
}
