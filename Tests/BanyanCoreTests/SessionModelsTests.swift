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
