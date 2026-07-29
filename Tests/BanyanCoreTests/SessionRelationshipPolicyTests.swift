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
