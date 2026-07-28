import Foundation
import Testing
@testable import BanyanCore

@Test func sidebarOrderingMovesOneSessionWithinItsGroup() {
    let result = SessionSidebarOrdering.reorderedIDs(
        activeIDs: ["outside", "a", "b", "c"],
        groupIDs: ["a", "b", "c"],
        sourceID: "a",
        targetID: "c"
    )

    #expect(result == ["outside", "b", "c", "a"])
}

@Test func sidebarOrderingMovesMultipleOffsetsAndPreservesOtherGroups() {
    let result = SessionSidebarOrdering.reorderedIDs(
        activeIDs: ["a", "outside", "b", "c", "d"],
        groupIDs: ["a", "b", "c", "d"],
        sourceOffsets: IndexSet([1, 2]),
        destinationOffset: 4
    )

    #expect(result == ["a", "outside", "d", "b", "c"])
}

@Test func sidebarOrderingRejectsInvalidGroupMembership() {
    #expect(SessionSidebarOrdering.reorderedIDs(
        activeIDs: ["a", "b"],
        groupIDs: ["a", "missing"],
        sourceID: "a",
        targetID: "missing"
    ) == nil)
}
