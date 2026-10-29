import BanyanCore
import Foundation
import Testing
@testable import Banyan

@MainActor
@Suite(.serialized) struct SessionSidebarCreationTests {
    private func fixture(daemon: FakePuckDaemon = FakePuckDaemon()) throws -> (PuckStoreFixture, SessionStore) {
        let fixture = try PuckStoreFixture(daemon: daemon)
        let parents = ["a1": "a", "grandchild": "a1", "a2": "a"]
        fixture.persistence.save(["a", "a1", "grandchild", "a2", "b", "c"].map { id in
            SessionSnapshot(id: id, tmuxSessionName: "banyan-\(id)", title: id,
                reportedTitle: nil, cwd: fixture.project.path, command: "", status: .closed,
                tone: .neutral, parentSessionID: parents[id], createdAt: Date(), updatedAt: Date())
        })
        let store = fixture.makeStore(sessionBackend: AdmissionTerminalBackend())
        store.loadPersistedSessionsIfNeeded()
        for session in store.sessions { session.status = .idle }
        store.sortMode = .manual
        store.collapsedParentIDs = []
        store.expandedParentIDs = []
        store.showFinishedChildren = true
        return (fixture, store)
    }

    private func rows(_ store: SessionStore) -> [SessionSidebarRow] {
        store.sessionSidebarGroups.flatMap(\.items).map { .init(id: $0.id, depth: $0.depth) }
    }

    @Test func siblingShortcutInsertsAfterSubtreeAndPersistsOrder() throws {
        let (fixture, store) = try fixture()
        defer { store.flushPendingSessionSaves() }
        store.selectedSessionID = "a1"
        let new = try #require(store.spawnSiblingSession())

        #expect(new.parentSessionID == "a")
        #expect(rows(store).map(\.id) == ["a", "a1", "grandchild", new.id, "a2", "b", "c"])
        #expect(rows(store).map(\.depth) == [0, 1, 2, 1, 1, 0, 0])
        #expect(store.selectedSessionID == new.id)
        store.flushPendingSessionSaves()
        #expect(fixture.persistence.load().map(\.id) == store.sessions.map(\.id))
    }

    @Test func projectHeaderUsesTheTargetRepresentativeWhenFocusIsElsewhere() throws {
        let (fixture, store) = try fixture()
        defer { store.flushPendingSessionSaves() }
        let groupID = try #require(store.sessions.first?.projectGroupID)
        let outside = store.spawn(id: "outside", cwd: fixture.home.path, command: "")
        #expect(outside.projectGroupID != groupID)
        let new = try #require(store.spawnSession(inProjectGroup: groupID, launch: .init(
            id: "zsh", label: "Terminal", providerName: nil, iconName: nil, command: ""
        )))

        #expect(new.parentSessionID == nil)
        #expect(rows(store).filter { $0.id != outside.id }.map(\.id) == [
            "a", "a1", "grandchild", "a2", new.id, "b", "c"
        ])
    }

    @Test func selectingACreatedChildExpandsItsCollapsedAncestors() throws {
        let (fixture, store) = try fixture()
        defer { store.flushPendingSessionSaves() }
        store.selectedSessionID = "a1"
        store.collapsedParentIDs = ["a", "a1"]
        let new = store.spawn(id: "new-child", cwd: fixture.project.path, command: "", parentSessionID: "a1")
        #expect(rows(store).contains { $0.id == new.id && $0.depth == 2 })
        #expect(store.collapsedParentIDs.isEmpty)
    }

    @Test func topLevelCreationFromANestedFocusKeepsTheExistingHierarchy() throws {
        let (fixture, store) = try fixture()
        defer { store.flushPendingSessionSaves() }
        store.selectedSessionID = "grandchild"
        let new = try #require(store.spawnPaletteAgentSessionInProjectRoot())
        #expect(new.parentSessionID == nil)
        #expect(rows(store).map(\.id) == ["a", "a1", "grandchild", "a2", new.id, "b", "c"])
        #expect(rows(store).map(\.depth) == [0, 1, 2, 1, 0, 0, 0])
        #expect(new.cwd == fixture.project.path)
    }

    @Test(arguments: [SortMode.status, .updated, .title])
    func creationLeavesExplicitSortingAuthoritative(sort: SortMode) throws {
        let (fixture, store) = try fixture()
        defer { store.flushPendingSessionSaves() }
        store.selectedSessionID = "a"
        store.sortMode = sort
        let new = store.spawn(id: "new", title: "ZZZ", cwd: fixture.project.path, command: "")
        #expect(store.sortMode == sort)
        #expect(store.sessions.last?.id == new.id)
        if sort == .title { #expect(rows(store).last?.id == new.id) }
        if sort == .updated { #expect(rows(store).first?.id == new.id) }
    }

    @Test func asynchronousPuckCreationRetainsItsOriginalPlacementAnchor() async throws {
        let daemon = FakePuckDaemon()
        let (fixture, store) = try fixture(daemon: daemon)
        defer { store.flushPendingSessionSaves() }
        let gate = daemon.holdCreates()
        defer { gate.signal() }
        store.selectedSessionID = "a1"
        let creation = Task {
            try await store.createPuckSession(binding: .init(provider: "codex"),
                cwd: fixture.project.path, id: "new-puck", parentSessionID: "a")
        }
        try await waitForPuckState { !daemon.creations.isEmpty }
        store.selectedSessionID = "a2"
        gate.signal()
        let new = try await creation.value
        #expect(rows(store).map(\.id) == ["a", "a1", "grandchild", new.id, "a2", "b", "c"])
        #expect(new.parentSessionID == "a")
        #expect(store.selectedSessionID == new.id)
    }
}
