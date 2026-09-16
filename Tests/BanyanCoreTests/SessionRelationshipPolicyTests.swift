import Testing
@testable import BanyanCore

@Test func relationshipPolicyCountsOnlyActiveChildren() {
    let items = [
        SessionRelationshipItem(id: "active", parentSessionID: "parent", status: .running),
        SessionRelationshipItem(id: "closed", parentSessionID: "parent", status: .closed),
        SessionRelationshipItem(id: "other", parentSessionID: "other-parent", status: .running)
    ]

    #expect(SessionRelationshipPolicy.activeChildCount(of: "parent", in: items) == 1)
}

@Test func relationshipPolicyNormalizesOnlyActiveParentIDs() {
    let activeIDs: Set<String> = ["parent"]

    #expect(SessionRelationshipPolicy.resolvedActiveParentID(
        "  parent ",
        activeSessionIDs: activeIDs
    ) == "parent")
    #expect(SessionRelationshipPolicy.resolvedActiveParentID(
        "closed",
        activeSessionIDs: activeIDs
    ) == nil)
    #expect(SessionRelationshipPolicy.resolvedActiveParentID(
        "   ",
        activeSessionIDs: activeIDs
    ) == nil)
}

@Test func relationshipPolicyFindsWaitingDescendantsAtAnyDepth() {
    let items = [
        SessionRelationshipItem(id: "parent", parentSessionID: nil, status: .running),
        SessionRelationshipItem(id: "middle", parentSessionID: "parent", status: .running),
        SessionRelationshipItem(id: "leaf", parentSessionID: "middle", status: .running)
    ]

    #expect(SessionRelationshipPolicy.hasWaitingDescendant(of: "parent", in: items) { $0.id == "leaf" })
    #expect(SessionRelationshipPolicy.hasWaitingDescendant(of: "middle", in: items) { $0.id == "leaf" })
    #expect(!SessionRelationshipPolicy.hasWaitingDescendant(of: "leaf", in: items) { _ in true })
    #expect(!SessionRelationshipPolicy.hasWaitingDescendant(of: "missing", in: items) { _ in true })
}

@Test func relationshipPolicyDescendantSearchIsCycleSafe() {
    let items = [
        SessionRelationshipItem(id: "a", parentSessionID: "b", status: .running),
        SessionRelationshipItem(id: "b", parentSessionID: "a", status: .running)
    ]

    #expect(!SessionRelationshipPolicy.hasWaitingDescendant(of: "a", in: items) { _ in false })
}
