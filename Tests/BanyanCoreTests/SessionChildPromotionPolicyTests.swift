import Testing
@testable import BanyanCore

private func sidebarItem(_ id: String, parent: String? = nil) -> SessionSelectionItem {
    SessionSelectionItem(id: id, parentSessionID: parent)
}

@Test func promotionMovesChildrenToGrandparentLevel() {
    #expect(SessionChildPromotionPolicy.promotedParentID(closingParentID: "P") == "P")
    #expect(SessionChildPromotionPolicy.promotedParentID(closingParentID: nil) == nil)
    #expect(SessionChildPromotionPolicy.promotedParentID(closingParentID: "  ") == nil)
}

@Test func promotionOnRemoveTakesParentSlotInAppendOrder() {
    // Children are appended at spawn time, so the array is A, B, C, B1, B2
    // while the sidebar shows A, B(B1, B2), C. Removing B must read
    // A, B1, B2, C — not A, C, B1, B2.
    let reordered = SessionChildPromotionPolicy.reorderedIDs(
        orderedIDs: ["A", "B", "C", "B1", "B2"],
        closingID: "B",
        promotedChildIDs: ["B1", "B2"],
        removingParent: true
    )
    #expect(reordered == ["A", "B1", "B2", "C"])
}

@Test func promotionOnCloseKeepsHiddenParentButSameVisibleOrder() {
    let reordered = SessionChildPromotionPolicy.reorderedIDs(
        orderedIDs: ["A", "B", "C", "B1", "B2"],
        closingID: "B",
        promotedChildIDs: ["B1", "B2"],
        removingParent: false
    )
    #expect(reordered == ["A", "B", "B1", "B2", "C"])
}

@Test func promotionKeepsOrderWhenChildrenAlreadyFollowParent() {
    let reordered = SessionChildPromotionPolicy.reorderedIDs(
        orderedIDs: ["A", "B", "B1", "B2", "C"],
        closingID: "B",
        promotedChildIDs: ["B1", "B2"],
        removingParent: true
    )
    #expect(reordered == ["A", "B1", "B2", "C"])
}

@Test func promotionHandlesNestedParent() {
    // P(A, B(B1, B2), C): closing B promotes B1, B2 to P's level at B's slot.
    let reordered = SessionChildPromotionPolicy.reorderedIDs(
        orderedIDs: ["P", "A", "B", "C", "B1", "B2"],
        closingID: "B",
        promotedChildIDs: ["B1", "B2"],
        removingParent: true
    )
    #expect(reordered == ["P", "A", "B1", "B2", "C"])
}

@Test func promotionReturnsNilWhenNothingToDo() {
    #expect(SessionChildPromotionPolicy.reorderedIDs(
        orderedIDs: ["A", "B", "C"],
        closingID: "B",
        promotedChildIDs: [],
        removingParent: true
    ) == nil)
    #expect(SessionChildPromotionPolicy.reorderedIDs(
        orderedIDs: ["A", "B", "C"],
        closingID: "missing",
        promotedChildIDs: ["B1"],
        removingParent: true
    ) == nil)
    #expect(SessionChildPromotionPolicy.reorderedIDs(
        orderedIDs: ["A", "B", "C"],
        closingID: "B",
        promotedChildIDs: ["ghost"],
        removingParent: true
    ) == nil)
}

@Test func closingParentRendersChildrenAsTopLevelInPlace() {
    // End-to-end through the sidebar hierarchy: after B closes, B1/B2 are
    // reparented to top level and sit where B was: A, B1, B2, C.
    let reordered = SessionChildPromotionPolicy.reorderedIDs(
        orderedIDs: ["A", "B", "C", "B1", "B2"],
        closingID: "B",
        promotedChildIDs: ["B1", "B2"],
        removingParent: true
    )!
    let rows = SessionSidebarHierarchyPolicy.rows(for: reordered.map {
        sidebarItem($0)
    })
    #expect(rows == [
        SessionSidebarRow(id: "A", depth: 0),
        SessionSidebarRow(id: "B1", depth: 0),
        SessionSidebarRow(id: "B2", depth: 0),
        SessionSidebarRow(id: "C", depth: 0),
    ])
}

/// Replays `SessionStore.remove` for a sequence of IDs: each removed
/// session's direct children move to its parent level and take its slot.
private func rowsAfterRemoving(
    _ removalOrder: [String],
    initialOrder: [String],
    initialParents: [String: String?]
) -> [SessionSidebarRow] {
    var order = initialOrder
    var parents = initialParents
    for closingID in removalOrder {
        let grandparent = parents[closingID] ?? nil
        let promoted = order.filter { parents[$0] ?? nil == closingID }
        for child in promoted {
            parents[child] = grandparent
        }
        if let reordered = SessionChildPromotionPolicy.reorderedIDs(
            orderedIDs: order,
            closingID: closingID,
            promotedChildIDs: promoted,
            removingParent: true
        ) {
            order = reordered
        } else {
            order.removeAll { $0 == closingID }
        }
        parents[closingID] = nil
    }
    return SessionSidebarHierarchyPolicy.rows(for: order.map {
        sidebarItem($0, parent: parents[$0] ?? nil)
    })
}

@Test func deletingAncestorsLeavesGrandchildrenAtTopLevel() {
    // A(A1, A2(A2.1, A2.2)): deleting A, A1 and A2 must leave A2.1/A2.2
    // at top level with indent 0, regardless of deletion order.
    let initialOrder = ["A", "A1", "A2", "A2.1", "A2.2"]
    let initialParents: [String: String?] = [
        "A": nil, "A1": "A", "A2": "A", "A2.1": "A2", "A2.2": "A2",
    ]
    let expected = [
        SessionSidebarRow(id: "A2.1", depth: 0),
        SessionSidebarRow(id: "A2.2", depth: 0),
    ]
    #expect(rowsAfterRemoving(["A", "A1", "A2"], initialOrder: initialOrder, initialParents: initialParents) == expected)
    #expect(rowsAfterRemoving(["A2", "A1", "A"], initialOrder: initialOrder, initialParents: initialParents) == expected)
    #expect(rowsAfterRemoving(["A1", "A2", "A"], initialOrder: initialOrder, initialParents: initialParents) == expected)
    #expect(rowsAfterRemoving(["A1", "A", "A2"], initialOrder: initialOrder, initialParents: initialParents) == expected)
}

@Test func closingNestedParentKeepsGrandchildrenUnderPromotedChild() {
    // B1 has its own child B1a: only direct children reparent, so the whole
    // subtree moves up exactly one level and renders after its subtree root.
    let reordered = SessionChildPromotionPolicy.reorderedIDs(
        orderedIDs: ["A", "B", "C", "B1", "B1a", "B2"],
        closingID: "B",
        promotedChildIDs: ["B1", "B2"],
        removingParent: true
    )!
    #expect(reordered == ["A", "B1", "B2", "C", "B1a"])
    let rows = SessionSidebarHierarchyPolicy.rows(for: [
        sidebarItem("A"),
        sidebarItem("B1"),
        sidebarItem("B2"),
        sidebarItem("C"),
        sidebarItem("B1a", parent: "B1"),
    ])
    #expect(rows == [
        SessionSidebarRow(id: "A", depth: 0),
        SessionSidebarRow(id: "B1", depth: 0),
        SessionSidebarRow(id: "B1a", depth: 1),
        SessionSidebarRow(id: "B2", depth: 0),
        SessionSidebarRow(id: "C", depth: 0),
    ])
}
