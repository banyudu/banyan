import Testing
@testable import Banyan

@Test func restoreKeepsClosedSessionsHiddenEvenWhenBackingTmuxSessionExists() {
    #expect(SessionStore.restoredStatus(snapshotStatus: .closed, backingSessionExists: true) == .closed)
}

@Test func restorePreservesActiveSessionStatus() {
    #expect(SessionStore.restoredStatus(snapshotStatus: .running, backingSessionExists: true) == .running)
    #expect(SessionStore.restoredStatus(snapshotStatus: .needInput, backingSessionExists: false) == .needInput)
}
