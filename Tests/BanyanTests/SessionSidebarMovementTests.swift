import BanyanCore
import Foundation
import Testing
@testable import Banyan

@MainActor
@Suite(.serialized) struct SessionSidebarMovementTests {
    private func fixture() throws -> (PuckStoreFixture, SessionStore, String) {
        let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
        let now = Date()
        let parents = ["a2": "a", "a1": "a"]
        fixture.persistence.save(["a", "a1", "a2", "b", "c"].map { id in
            SessionSnapshot(
                id: id,
                tmuxSessionName: "banyan-\(id)",
                title: "Title \(id)",
                reportedTitle: nil,
                cwd: fixture.project.path,
                command: "fixture-agent",
                status: .closed,
                tone: .purple,
                parentSessionID: parents[id],
                createdAt: now,
                updatedAt: now
            )
        })
        let store = fixture.makeStore(sessionBackend: AdmissionTerminalBackend())
        store.loadPersistedSessionsIfNeeded()
        for session in store.sessions { session.status = .idle }
        store.sortMode = .manual
        store.sidebarScope = .all
        store.foldedParentIDs = []
        store.saveSessions()
        store.flushPendingSessionSaves()
        let groupID = try #require(store.sessionSidebarGroups.first?.id)
        return (fixture, store, groupID)
    }

    private func session(_ id: String, in store: SessionStore) throws -> BanyanSession {
        try #require(store.sessions.first { $0.id == id })
    }

    private func visibleRows(in store: SessionStore) -> [SessionSidebarRow] {
        store.sessionSidebarGroups.flatMap(\.items).map {
            SessionSidebarRow(id: $0.id, depth: $0.depth)
        }
    }

    @Test func collapseToggleHidesSelectedAndAttentionChildrenUntilExpanded() throws {
        let (_, store, _) = try fixture()
        defer { store.flushPendingSessionSaves() }
        try session("a1", in: store).status = .asking
        try session("a2", in: store).status = .needInput
        try session("b", in: store).parentSessionID = "a1"
        try session("b", in: store).status = .failed
        store.userSelect(id: "b")
        let expandedRows = visibleRows(in: store)
        #expect(expandedRows.map(\.id) == ["a", "a1", "b", "a2", "c"])

        store.toggleChildrenFolded(for: "a")

        #expect(visibleRows(in: store).map(\.id) == ["a", "c"])
        let parent = try #require(store.sessionSidebarGroups.flatMap(\.items).first { $0.id == "a" })
        #expect(parent.isFolded)
        #expect(store.selectedSessionID == "b")

        store.toggleChildrenFolded(for: "a")
        #expect(visibleRows(in: store) == expandedRows)

        store.toggleChildrenFolded(for: "a")
        store.userSelect(id: "b")
        #expect(visibleRows(in: store) == expandedRows)
    }

    @Test func focusShowsInputAndFinishedRowsButHidesWorkingRows() throws {
        let (_, store, _) = try fixture()
        defer { store.flushPendingSessionSaves() }
        try session("a", in: store).status = .executing
        try session("a1", in: store).status = .executing
        try session("a2", in: store).status = .needInput
        try session("b", in: store).parentSessionID = "a"
        try session("b", in: store).status = .completed
        try session("c", in: store).status = .executing
        store.sidebarScope = .focus

        #expect(visibleRows(in: store) == [
            SessionSidebarRow(id: "a", depth: 0),
            SessionSidebarRow(id: "a2", depth: 1),
            SessionSidebarRow(id: "b", depth: 1),
        ])

        store.userSelect(id: "a1")
        #expect(visibleRows(in: store) == [
            SessionSidebarRow(id: "a", depth: 0),
            SessionSidebarRow(id: "a1", depth: 1),
            SessionSidebarRow(id: "a2", depth: 1),
            SessionSidebarRow(id: "b", depth: 1),
        ])
    }

    @Test func focusKeepsProjectHeaderWhenAllItsSessionsAreHidden() throws {
        let (_, store, groupID) = try fixture()
        defer { store.flushPendingSessionSaves() }
        let groupTitle = try #require(store.sessionSidebarGroups.first?.title)
        for session in store.sessions { session.status = .executing }
        store.selectedSessionID = nil
        store.sidebarScope = .focus

        let group = try #require(store.sessionSidebarGroups.first)
        #expect(group.id == groupID)
        #expect(group.title == groupTitle)
        #expect(group.items.isEmpty)
        #expect(store.unifiedSidebarGroups.map(\.id) == [groupID])
        #expect(store.hiddenSessionCount == 5)
        #expect(store.sidebarSessionIDs(limit: 9).isEmpty)

        store.sidebarScope = .all
        #expect(store.sessionSidebarGroups.map(\.id) == [groupID])
        #expect(visibleRows(in: store).map(\.id) == ["a", "a1", "a2", "b", "c"])
        #expect(store.hiddenSessionCount == 0)

        store.sidebarScope = .focus
        for session in store.sessions { session.status = .closed }
        #expect(store.sessionSidebarGroups.isEmpty)
        #expect(store.hiddenSessionCount == 0)
    }

    @Test func selectedParentCanFoldAndUnfoldChildrenDirectly() throws {
        let (_, store, _) = try fixture()
        defer { store.flushPendingSessionSaves() }
        store.userSelect(id: "a")

        #expect(store.selectedSessionChildrenFoldState == false)
        #expect(store.setSelectedSessionChildrenFolded(true))
        #expect(store.foldedParentIDs.contains("a"))
        #expect(store.selectedSessionChildrenFoldState == true)
        #expect(visibleRows(in: store).map(\.id) == ["a", "b", "c"])

        #expect(store.setSelectedSessionChildrenFolded(false))
        #expect(!store.foldedParentIDs.contains("a"))
        #expect(visibleRows(in: store).map(\.id) == ["a", "a1", "a2", "b", "c"])

        store.userSelect(id: "a1")
        #expect(store.selectedSessionChildrenFoldState == nil)
        #expect(!store.setSelectedSessionChildrenFolded(true))
        #expect(!store.foldedParentIDs.contains("a1"))
    }

    @Test func indentAndOutdentUpdateHierarchyWithoutChangingRowOrder() throws {
        let (fixture, store, groupID) = try fixture()
        defer { store.flushPendingSessionSaves() }

        store.moveSidebarSession("b", command: .indent, in: groupID)

        #expect(try session("b", in: store).parentSessionID == "a")
        #expect(visibleRows(in: store) == [
            SessionSidebarRow(id: "a", depth: 0),
            SessionSidebarRow(id: "a1", depth: 1),
            SessionSidebarRow(id: "a2", depth: 1),
            SessionSidebarRow(id: "b", depth: 1),
            SessionSidebarRow(id: "c", depth: 0)
        ])
        store.flushPendingSessionSaves()
        #expect(fixture.persistence.load().first { $0.id == "b" }?.parentSessionID == "a")

        store.moveSidebarSession("b", command: .outdent, in: groupID)

        #expect(try session("b", in: store).parentSessionID == nil)
        #expect(visibleRows(in: store) == [
            SessionSidebarRow(id: "a", depth: 0),
            SessionSidebarRow(id: "a1", depth: 1),
            SessionSidebarRow(id: "a2", depth: 1),
            SessionSidebarRow(id: "b", depth: 0),
            SessionSidebarRow(id: "c", depth: 0)
        ])
        store.flushPendingSessionSaves()
        #expect(fixture.persistence.load().first { $0.id == "b" }?.parentSessionID == nil)
    }

    @Test func siblingCommandsMoveWholeSubtreesAndPersistManualOrder() throws {
        let (fixture, store, groupID) = try fixture()
        defer { store.flushPendingSessionSaves() }

        store.moveSidebarSession("a", command: .down, in: groupID)

        #expect(store.sessions.map(\.id) == ["b", "a", "a1", "a2", "c"])
        #expect(visibleRows(in: store) == [
            SessionSidebarRow(id: "b", depth: 0),
            SessionSidebarRow(id: "a", depth: 0),
            SessionSidebarRow(id: "a1", depth: 1),
            SessionSidebarRow(id: "a2", depth: 1),
            SessionSidebarRow(id: "c", depth: 0)
        ])
        store.flushPendingSessionSaves()
        #expect(fixture.persistence.load().map(\.id) == ["b", "a", "a1", "a2", "c"])
    }

    @Test func dragCommandsUseEdgeAndCenterDestinations() throws {
        let (_, store, groupID) = try fixture()
        defer { store.flushPendingSessionSaves() }

        store.moveSidebarSession("c", command: .before("a"), in: groupID)
        #expect(visibleRows(in: store).map(\.id) == ["c", "a", "a1", "a2", "b"])

        store.foldedParentIDs = ["b"]
        store.moveSidebarSession("a", command: .child("b"), in: groupID)
        #expect(try session("a", in: store).parentSessionID == "b")
        #expect(!store.foldedParentIDs.contains("b"))
        #expect(visibleRows(in: store) == [
            SessionSidebarRow(id: "c", depth: 0),
            SessionSidebarRow(id: "b", depth: 0),
            SessionSidebarRow(id: "a", depth: 1),
            SessionSidebarRow(id: "a1", depth: 2),
            SessionSidebarRow(id: "a2", depth: 2)
        ])
        #expect(store.canMoveSidebarSession("a", command: .before("a1"), in: groupID) == false)
        #expect(store.canMoveSidebarSession("b", command: .child("a"), in: groupID) == false)
    }

    @Test func moveOptionsAndTopLevelFollowTheVisibleHierarchy() throws {
        let (_, store, groupID) = try fixture()
        defer { store.flushPendingSessionSaves() }

        let items = try #require(store.sessionSidebarGroups.first { $0.id == groupID }?.items)
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        #expect(byID["a"]?.moveOptions == [.down])
        #expect(byID["a1"]?.moveOptions == [.down, .outdent, .topLevel])
        #expect(byID["b"]?.moveOptions == [.up, .indent, .down])

        store.moveSidebarSession("a2", command: .topLevel, in: groupID)

        #expect(try session("a2", in: store).parentSessionID == nil)
        #expect(visibleRows(in: store) == [
            SessionSidebarRow(id: "a", depth: 0),
            SessionSidebarRow(id: "a1", depth: 1),
            SessionSidebarRow(id: "b", depth: 0),
            SessionSidebarRow(id: "c", depth: 0),
            SessionSidebarRow(id: "a2", depth: 0)
        ])
    }
}
