import BanyanCore
import Testing

@Test func adjacentSelectionWrapsForwardAndBackward() {
    let ids = ["one", "two", "three"]

    #expect(SessionSelectionNavigator.adjacentID(in: ids, selectedID: "one", direction: .next) == "two")
    #expect(SessionSelectionNavigator.adjacentID(in: ids, selectedID: "three", direction: .next) == "one")
    #expect(SessionSelectionNavigator.adjacentID(in: ids, selectedID: "three", direction: .previous) == "two")
    #expect(SessionSelectionNavigator.adjacentID(in: ids, selectedID: "one", direction: .previous) == "three")
}

@Test func adjacentSelectionFallsBackWhenCurrentSelectionIsMissing() {
    let ids = ["one", "two", "three"]

    #expect(SessionSelectionNavigator.adjacentID(in: ids, selectedID: nil, direction: .next) == "one")
    #expect(SessionSelectionNavigator.adjacentID(in: ids, selectedID: "missing", direction: .next) == "one")
    #expect(SessionSelectionNavigator.adjacentID(in: ids, selectedID: nil, direction: .previous) == "three")
    #expect(SessionSelectionNavigator.adjacentID(in: ids, selectedID: "missing", direction: .previous) == "three")
}

@Test func adjacentSelectionReturnsNilForEmptySessionList() {
    #expect(SessionSelectionNavigator.adjacentID(in: [], selectedID: "one", direction: .next) == nil)
    #expect(SessionSelectionNavigator.adjacentID(in: [], selectedID: "one", direction: .previous) == nil)
}

@Test func directSelectionUsesOneBasedIndexes() {
    let ids = ["one", "two", "three"]

    #expect(SessionSelectionNavigator.directID(in: ids, oneBasedIndex: 1) == "one")
    #expect(SessionSelectionNavigator.directID(in: ids, oneBasedIndex: 3) == "three")
    #expect(SessionSelectionNavigator.directID(in: ids, oneBasedIndex: 0) == nil)
    #expect(SessionSelectionNavigator.directID(in: ids, oneBasedIndex: 4) == nil)
}
