import Testing
@testable import BanyanCore

@Suite struct SessionSidebarCreationPolicyTests {
    private let candidates: [SessionSidebarCandidate] = [
        .init(id: "a", groupID: "project", groupTitle: "Project", parentSessionID: nil),
        .init(id: "a1", groupID: "project", groupTitle: "Project", parentSessionID: "a"),
        .init(id: "other", groupID: "other-project", groupTitle: "Other", parentSessionID: nil),
        .init(id: "grandchild", groupID: "project", groupTitle: "Project", parentSessionID: "a1"),
        .init(id: "a2", groupID: "project", groupTitle: "Project", parentSessionID: "a"),
        .init(id: "b", groupID: "project", groupTitle: "Project", parentSessionID: nil),
        .init(id: "c", groupID: "project", groupTitle: "Project", parentSessionID: nil)
    ]

    private func next(parent: String? = nil, focused: String?, sort: SortMode = .manual) -> String? {
        SessionSidebarCreationPolicy.insertionBeforeID(in: candidates, groupID: "project",
            parentSessionID: parent, focusedSessionID: focused, sortMode: sort)
    }

    @Test func skipsTheFocusedSessionsEntireSubtree() {
        #expect(next(focused: "a") == "b")
        #expect(next(parent: "a", focused: "a1") == "a2")
    }

    @Test func climbsToTheNewSessionsSiblingLevel() {
        #expect(next(focused: "grandchild") == "b")
        #expect(next(parent: "a", focused: "grandchild") == "a2")
    }

    @Test func usesTheProjectRepresentativeForAnOutsideOrMissingFocus() {
        #expect(next(focused: "other") == "b")
        #expect(next(focused: nil) == "b")
        #expect(next(focused: "removed") == "b")
    }

    @Test func appendsAfterTheLastSiblingOrForANewChild() {
        #expect(next(focused: "c") == nil)
        #expect(next(parent: "a", focused: "a2") == "b")
        #expect(next(parent: "a1", focused: "a1") == nil)
    }

    @Test(arguments: [SortMode.status, .updated, .title])
    func sortedModesDoNotRequestManualInsertion(sort: SortMode) {
        #expect(next(focused: "a", sort: sort) == nil)
    }

    @Test func siblingBoundaryDoesNotDependOnContiguousStorageOfChildren() {
        let interleaved = [candidates[0], candidates[5], candidates[1], candidates[6], candidates[4], candidates[3]]
        #expect(SessionSidebarCreationPolicy.insertionBeforeID(in: interleaved, groupID: "project",
            parentSessionID: nil, focusedSessionID: "a1", sortMode: .manual) == "b")
    }
}
