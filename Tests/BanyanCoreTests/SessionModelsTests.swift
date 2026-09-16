import Foundation
import Testing
@testable import BanyanCore

@Test func sessionModelsPreserveMacOSDisplaySemantics() {
    #expect(SessionStatus.needInput.rawValue == "need-input")
    #expect(SessionStatus.needInput.isCodingAgentIdle)
    #expect(SessionStatus.asking.priority < SessionStatus.running.priority)
    #expect(SessionStatus.closed.label == "Closed")
    #expect(SessionStatus.completed.emoji == "✅")
    #expect(SessionTone.purple.label == "Purple")
    #expect(SortMode.updated.label == "Updated")
}

@Test func visibilityPolicyFiltersClosedSessionsAndPreservesManualOrder() {
    let items = [
        SessionVisibilityItem(id: "first", status: .running, updatedAt: .init(timeIntervalSince1970: 100), displayTitle: "First"),
        SessionVisibilityItem(id: "closed", status: .closed, updatedAt: .init(timeIntervalSince1970: 300), displayTitle: "Closed"),
        SessionVisibilityItem(id: "second", status: .asking, updatedAt: .init(timeIntervalSince1970: 200), displayTitle: "Second")
    ]

    #expect(SessionVisibilityPolicy.visibleIDs(from: items, sortMode: .manual) == ["first", "second"])
}

@Test func visibilityPolicySortsByStatusUpdatedTimeAndTitle() {
    let items = [
        SessionVisibilityItem(id: "running", status: .running, updatedAt: .init(timeIntervalSince1970: 300), displayTitle: "Zulu"),
        SessionVisibilityItem(id: "asking-old", status: .asking, updatedAt: .init(timeIntervalSince1970: 100), displayTitle: "Beta"),
        SessionVisibilityItem(id: "asking-new", status: .asking, updatedAt: .init(timeIntervalSince1970: 200), displayTitle: "Alpha")
    ]

    #expect(SessionVisibilityPolicy.visibleIDs(from: items, sortMode: .status) == ["asking-new", "asking-old", "running"])
    #expect(SessionVisibilityPolicy.visibleIDs(from: items, sortMode: .updated) == ["running", "asking-new", "asking-old"])
    #expect(SessionVisibilityPolicy.visibleIDs(from: items, sortMode: .title) == ["asking-new", "asking-old", "running"])
}

@Test func visibilityPolicySinksSuspendedSessionsBelowActiveOnesInEverySortMode() {
    let items = [
        SessionVisibilityItem(
            id: "parked-asking",
            status: .asking,
            updatedAt: .init(timeIntervalSince1970: 300),
            displayTitle: "Alpha",
            isSuspended: true
        ),
        SessionVisibilityItem(
            id: "live-running",
            status: .running,
            updatedAt: .init(timeIntervalSince1970: 100),
            displayTitle: "Zulu"
        ),
        SessionVisibilityItem(
            id: "parked-running",
            status: .running,
            updatedAt: .init(timeIntervalSince1970: 200),
            displayTitle: "Bravo",
            isSuspended: true
        )
    ]

    // `parked-asking` outranks `live-running` on status, recency and title, yet
    // still sorts last everywhere: parking is what removed it from contention.
    for sortMode in SortMode.allCases {
        #expect(
            SessionVisibilityPolicy.visibleIDs(from: items, sortMode: sortMode).first == "live-running",
            "\(sortMode) should keep the unparked session on top"
        )
    }

    // Parked rows keep the order their sort mode gave them.
    #expect(SessionVisibilityPolicy.visibleIDs(from: items, sortMode: .status)
        == ["live-running", "parked-asking", "parked-running"])
    #expect(SessionVisibilityPolicy.visibleIDs(from: items, sortMode: .title)
        == ["live-running", "parked-asking", "parked-running"])
    #expect(SessionVisibilityPolicy.visibleIDs(from: items, sortMode: .manual)
        == ["live-running", "parked-asking", "parked-running"])
}
