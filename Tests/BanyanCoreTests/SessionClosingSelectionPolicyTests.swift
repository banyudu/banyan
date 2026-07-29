import Testing
@testable import BanyanCore

private func selectionItem(_ id: String, parent: String? = nil) -> SessionSelectionItem {
    SessionSelectionItem(id: id, parentSessionID: parent)
}

@Test func closingSelectionPrefersNextSiblingThenPreviousSibling() {
    let groups = [
        SessionSelectionGroup(
            id: "project",
            items: [selectionItem("parent"), selectionItem("closing", parent: "parent"), selectionItem("next", parent: "parent"), selectionItem("other")]
        )
    ]

    #expect(SessionClosingSelectionPolicy.preferredIDAfterClosing(closingID: "closing", groups: groups) == "next")
    #expect(SessionClosingSelectionPolicy.preferredIDAfterClosing(closingID: "next", groups: groups) == "closing")
}

@Test func closingSelectionFallsBackAcrossGroups() {
    let groups = [
        SessionSelectionGroup(id: "first", items: [selectionItem("first-session")]),
        SessionSelectionGroup(id: "second", items: [selectionItem("closing")]),
        SessionSelectionGroup(id: "third", items: [selectionItem("third-session")])
    ]

    #expect(SessionClosingSelectionPolicy.preferredIDAfterClosing(closingID: "closing", groups: groups) == "third-session")
    #expect(SessionClosingSelectionPolicy.preferredIDAfterClosing(closingID: "first-session", groups: groups) == "closing")
}

@Test func closingSelectionReturnsNilWhenThereIsNoCandidate() {
    let groups = [SessionSelectionGroup(id: "project", items: [selectionItem("only")])]

    #expect(SessionClosingSelectionPolicy.preferredIDAfterClosing(closingID: "only", groups: groups) == nil)
    #expect(SessionClosingSelectionPolicy.preferredIDAfterClosing(closingID: "missing", groups: groups) == nil)
}
