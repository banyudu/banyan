import BanyanCore
import Foundation
import Testing
@testable import Banyan

@MainActor
@Suite(.serialized) struct SessionAttentionNavigationTests {
    @Test func idleSessionsEnableBothDirectionsAndWrap() throws {
        let fixture = try WorkflowStoreFixture(sessionIDs: ["first", "busy", "last"])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = fixture.makeStore()
        defer { store.flushPendingSessionSaves() }
        store.loadPersistedSessionsIfNeeded()
        store.sidebarScope = .all
        store.sortMode = .title
        for session in store.sessions {
            session.title = session.id
            session.isTitlePinned = true
            session.status = session.id == "busy" ? .executing : .idle
        }
        try #require(store.sidebarSessions.map(\.id) == ["busy", "first", "last"])
        store.selectedSessionID = "busy"

        #expect(store.canSelectSessionNeedingAttention)
        store.selectNextSessionNeedingAttention()
        #expect(store.selectedSessionID == "first")
        store.selectNextSessionNeedingAttention()
        #expect(store.selectedSessionID == "last")
        store.selectNextSessionNeedingAttention()
        #expect(store.selectedSessionID == "first")
        store.selectPreviousSessionNeedingAttention()
        #expect(store.selectedSessionID == "last")
        store.selectPreviousSessionNeedingAttention()
        #expect(store.selectedSessionID == "first")

        let last = try #require(store.sessions.first { $0.id == "last" })
        last.isSuspended = true
        #expect(!store.canSelectSessionNeedingAttention)
        store.selectNextSessionNeedingAttention()
        store.selectPreviousSessionNeedingAttention()
        #expect(store.selectedSessionID == "first")
        #expect(last.isSuspended)
    }

    @Test func idleChildKeepsItsParentsPendingQuestionReachable() throws {
        let fixture = try WorkflowStoreFixture(sessionIDs: ["parent", "child", "busy"])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = fixture.makeStore()
        defer { store.flushPendingSessionSaves() }
        store.loadPersistedSessionsIfNeeded()
        store.sidebarScope = .all
        store.sortMode = .title
        store.foldedParentIDs = []
        let parent = try #require(store.sessions.first { $0.id == "parent" })
        let child = try #require(store.sessions.first { $0.id == "child" })
        parent.status = .asking
        child.status = .idle
        child.parentSessionID = parent.id
        store.selectedSessionID = child.id

        #expect(store.canSelectSessionNeedingAttention)
        store.selectPreviousSessionNeedingAttention()
        #expect(store.selectedSessionID == parent.id)
        store.selectNextSessionNeedingAttention()
        #expect(store.selectedSessionID == child.id)

        parent.status = .idle
        child.status = .asking
        #expect(!store.canSelectSessionNeedingAttention)
        store.selectPreviousSessionNeedingAttention()
        #expect(store.selectedSessionID == child.id)
    }
}
