import Testing
@testable import BanyanCore

private func moveItem(_ id: String, parent: String? = nil) -> SessionSelectionItem {
    SessionSelectionItem(id: id, parentSessionID: parent)
}

@Test func sidebarMoveOptionsFollowSiblingEdgesAndDepth() {
    let items = [
        moveItem("a"),
        moveItem("a1", parent: "a"),
        moveItem("a2", parent: "a"),
        moveItem("b")
    ]

    #expect(SessionSidebarMovePolicy.options(for: "a", in: items) == [.down])
    #expect(SessionSidebarMovePolicy.options(for: "a1", in: items) == [.down, .outdent, .topLevel])
    #expect(SessionSidebarMovePolicy.options(for: "a2", in: items) == [.up, .indent, .outdent, .topLevel])
    #expect(SessionSidebarMovePolicy.options(for: "b", in: items) == [.up, .indent])
}

@Test func sidebarMoveUpAndDownStayWithinSiblingsAndMoveTheSubtree() {
    let items = [
        moveItem("a"),
        moveItem("a1", parent: "a"),
        moveItem("a2", parent: "a"),
        moveItem("b"),
        moveItem("c")
    ]

    let up = SessionSidebarMovePolicy.move(sourceID: "c", command: .up, in: items)
    #expect(up == SessionSidebarMoveResult(
        parentSessionID: nil,
        orderedIDs: ["a", "a1", "a2", "c", "b"]
    ))

    let down = SessionSidebarMovePolicy.move(sourceID: "a", command: .down, in: items)
    #expect(down == SessionSidebarMoveResult(
        parentSessionID: nil,
        orderedIDs: ["b", "a", "a1", "a2", "c"]
    ))
}

@Test func sidebarIndentNestsUnderPreviousSiblingAtTheEndOfItsChildren() {
    let items = [
        moveItem("a"),
        moveItem("a1", parent: "a"),
        moveItem("b"),
        moveItem("c")
    ]

    let result = SessionSidebarMovePolicy.move(sourceID: "b", command: .indent, in: items)

    #expect(result == SessionSidebarMoveResult(
        parentSessionID: "a",
        orderedIDs: ["a", "a1", "b", "c"]
    ))
}

@Test func sidebarOutdentPlacesSourceAfterItsFormerParentSubtree() {
    let items = [
        moveItem("a"),
        moveItem("a1", parent: "a"),
        moveItem("a2", parent: "a"),
        moveItem("a2x", parent: "a2"),
        moveItem("a3", parent: "a"),
        moveItem("b")
    ]

    let result = SessionSidebarMovePolicy.move(sourceID: "a2", command: .outdent, in: items)

    #expect(result == SessionSidebarMoveResult(
        parentSessionID: nil,
        orderedIDs: ["a", "a1", "a3", "a2", "a2x", "b"]
    ))
}

@Test func sidebarTopLevelAppendsToRootSiblings() {
    let items = [
        moveItem("a"),
        moveItem("a1", parent: "a"),
        moveItem("a1x", parent: "a1"),
        moveItem("b")
    ]

    let result = SessionSidebarMovePolicy.move(sourceID: "a1", command: .topLevel, in: items)

    #expect(result == SessionSidebarMoveResult(
        parentSessionID: nil,
        orderedIDs: ["a", "b", "a1", "a1x"]
    ))
}

@Test func sidebarDropBeforeAndAfterUsesTheTargetLevel() {
    let items = [
        moveItem("a"),
        moveItem("a1", parent: "a"),
        moveItem("a2", parent: "a"),
        moveItem("b"),
        moveItem("b1", parent: "b")
    ]

    #expect(SessionSidebarMovePolicy.move(
        sourceID: "b",
        command: .before("a1"),
        in: items
    ) == SessionSidebarMoveResult(
        parentSessionID: "a",
        orderedIDs: ["a", "b", "b1", "a1", "a2"]
    ))

    #expect(SessionSidebarMovePolicy.move(
        sourceID: "a1",
        command: .after("b"),
        in: items
    ) == SessionSidebarMoveResult(
        parentSessionID: nil,
        orderedIDs: ["a", "a2", "b", "b1", "a1"]
    ))
}

@Test func sidebarCenterDropAppendsAsLastChild() {
    let items = [
        moveItem("a"),
        moveItem("a1", parent: "a"),
        moveItem("b")
    ]

    #expect(SessionSidebarMovePolicy.move(
        sourceID: "b",
        command: .child("a"),
        in: items
    ) == SessionSidebarMoveResult(
        parentSessionID: "a",
        orderedIDs: ["a", "a1", "b"]
    ))
}

@Test func sidebarMoveRejectsCyclesAndInvalidTargets() {
    let items = [
        moveItem("a"),
        moveItem("a1", parent: "a"),
        moveItem("a1x", parent: "a1"),
        moveItem("b")
    ]

    #expect(SessionSidebarMovePolicy.move(sourceID: "a", command: .child("a1"), in: items) == nil)
    #expect(SessionSidebarMovePolicy.move(sourceID: "a1", command: .before("a1x"), in: items) == nil)
    #expect(SessionSidebarMovePolicy.move(sourceID: "a", command: .before("missing"), in: items) == nil)
    #expect(SessionSidebarMovePolicy.move(sourceID: "a", command: .up, in: items) == nil)
}
