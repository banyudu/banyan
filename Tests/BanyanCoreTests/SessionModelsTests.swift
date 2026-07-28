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
