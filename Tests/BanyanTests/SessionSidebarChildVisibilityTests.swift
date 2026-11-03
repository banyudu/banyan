import BanyanCore
import Foundation
import Testing
@testable import Banyan

@MainActor
@Suite(.serialized) struct SessionSidebarChildVisibilityTests {
    private func fixture() throws -> SessionStore {
        let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
        let parents = [
            "live-child": "parent",
            "closed-child": "parent",
            "live-grandchild": "gone",
            "closed-sibling": "gone",
        ]
        let closed = Set(["closed-child", "closed-sibling", "gone", "closed-root"])
        fixture.persistence.save(
            ["parent", "live-child", "closed-child", "gone", "live-grandchild", "closed-sibling", "closed-root"].map { id in
                SessionSnapshot(
                    id: id,
                    tmuxSessionName: "banyan-\(id)",
                    title: id,
                    reportedTitle: nil,
                    cwd: fixture.project.path,
                    command: "",
                    status: .closed,
                    tone: .neutral,
                    parentSessionID: parents[id],
                    createdAt: Date(),
                    updatedAt: Date()
                )
            }
        )
        let store = fixture.makeStore(sessionBackend: AdmissionTerminalBackend())
        store.loadPersistedSessionsIfNeeded()
        for session in store.sessions where !closed.contains(session.id) {
            session.status = .idle
        }
        store.sidebarScope = .all
        store.sortMode = .manual
        store.foldedParentIDs = []
        return store
    }

    private func rows(_ store: SessionStore) -> [SidebarSessionItem] {
        store.sessionSidebarGroups.flatMap(\.items)
    }

    @Test func unfoldingKeepsClosedChildrenInTheirParentsTree() throws {
        let store = try fixture()
        defer { store.flushPendingSessionSaves() }

        let visible = rows(store)
        #expect(visible.map(\.id) == [
            "parent", "live-child", "closed-child",
            "gone", "live-grandchild", "closed-sibling",
        ])
        #expect(visible.map(\.depth) == [0, 1, 1, 0, 1, 1])
        #expect(visible.first { $0.id == "parent" }?.isParent == true)
        #expect(visible.first { $0.id == "closed-child" }?.isHistory == true)
        #expect(visible.first { $0.id == "closed-sibling" }?.isHistory == true)
        #expect(!visible.contains { $0.id == "closed-root" })

        store.foldedParentIDs = ["parent"]
        #expect(rows(store).map(\.id) == [
            "parent", "gone", "live-grandchild", "closed-sibling",
        ])
        #expect(rows(store).first { $0.id == "parent" }?.isFolded == true)

        store.foldedParentIDs = []
        #expect(rows(store).map(\.id).contains("closed-child"))
    }
}
