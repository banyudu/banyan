import BanyanCore
import Foundation
import Testing
@testable import Banyan

@MainActor
@Suite(.serialized) struct SessionReparentingTests {
    private func fixture() throws -> (PuckStoreFixture, SessionStore, AdmissionTerminalBackend) {
        let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
        let now = Date()
        let parents = ["source": "old", "child": "source", "leaf": "child", "hidden": "target"]
        fixture.persistence.save(["old", "source", "target", "child", "leaf", "hidden", "closed", "foreign"].map { id in
            SessionSnapshot(id: id, tmuxSessionName: "banyan-\(id)", title: "Title \(id)",
                reportedTitle: "reported \(id)", generatedTitle: "generated \(id)", isTitlePinned: true,
                cwd: fixture.project.path, command: "fixture-agent", status: .closed, tone: .purple,
                parentSessionID: parents[id], agentSessionID: "conversation-\(id)", createdAt: now, updatedAt: now)
        })
        let backend = AdmissionTerminalBackend()
        let store = fixture.makeStore(sessionBackend: backend)
        store.loadPersistedSessionsIfNeeded()
        for session in store.sessions where session.id != "closed" { session.status = .idle }
        try #require(store.sessions.first { $0.id == "foreign" }).projectGroupID = "other-project"
        store.sortMode = .manual
        store.collapsedParentIDs = []
        store.expandedParentIDs = []
        store.showFinishedChildren = true
        store.selectedSessionID = nil
        store.saveSessions()
        store.flushPendingSessionSaves()
        return (fixture, store, backend)
    }

    private func session(_ id: String, in store: SessionStore) throws -> BanyanSession {
        try #require(store.sessions.first { $0.id == id })
    }

    private func metadata(_ snapshot: SessionSnapshot) throws -> NSDictionary {
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        json.removeValue(forKey: "parentSessionID")
        return json as NSDictionary
    }

    @Test func movePreservesObjectProcessMetadataOrderAndSubtreeAndSurvivesReload() throws {
        let (fixture, store, backend) = try fixture()
        defer { store.flushPendingSessionSaves() }
        let source = try session("source", in: store)
        let originalOrder = store.sessions.map(\.id)
        let before = store.sessions.map(\.persistenceSnapshot)
        try backend.ensureSession(named: "banyan-source", cwd: source.cwd, command: source.command, banyanSessionID: source.id)
        let launches = backend.started
        _ = store.sessionSidebarGroups // Prime the hierarchy cache before the move.
        let moved = try store.reparent(id: source.id, parentSessionID: "target")
        #expect(moved === source)
        #expect(source.parentSessionID == "target")
        #expect(try session("child", in: store).parentSessionID == source.id)
        #expect(try session("leaf", in: store).parentSessionID == "child")
        #expect(store.sessions.map(\.id) == originalOrder)
        #expect(store.sortMode == .manual)
        #expect(backend.started == launches)
        #expect(backend.hasSession(named: "banyan-source"))
        for (old, new) in zip(before, store.sessions.map(\.persistenceSnapshot)) {
            #expect(try metadata(old) == metadata(new))
        }
        let rows = store.sessionSidebarGroups.flatMap(\.items)
        #expect(rows.filter { ["target", "source", "child", "leaf"].contains($0.id) }.map(\.id) == ["target", "source", "child", "leaf"])
        #expect(rows.first { $0.id == "source" }?.depth == 1)
        #expect(rows.first { $0.id == "leaf" }?.depth == 3)
        store.flushPendingSessionSaves()
        #expect(fixture.persistence.load().first { $0.id == "source" }?.parentSessionID == "target")

        let restored = fixture.makeStore(sessionBackend: backend)
        restored.loadPersistedSessionsIfNeeded()
        defer { restored.flushPendingSessionSaves() }
        #expect(try session("source", in: restored).parentSessionID == "target")
        #expect(try session("child", in: restored).parentSessionID == "source")
        #expect(try session("leaf", in: restored).parentSessionID == "child")
        restored.flushPendingSessionSaves()

        try store.reparent(id: "source", parentSessionID: nil)
        #expect(source.parentSessionID == nil)
        #expect(store.sessionSidebarGroups.flatMap(\.items).first { $0.id == "source" }?.depth == 0)
        #expect(store.sessions.map(\.id) == originalOrder)
        store.flushPendingSessionSaves()
        #expect(fixture.persistence.load().first { $0.id == "source" }?.parentSessionID == nil)
        let rootRestored = fixture.makeStore(sessionBackend: backend)
        rootRestored.loadPersistedSessionsIfNeeded()
        defer { rootRestored.flushPendingSessionSaves() }
        #expect(try session("source", in: rootRestored).parentSessionID == nil)
        #expect(try session("child", in: rootRestored).parentSessionID == "source")
    }

    @Test func rejectedMovesLeaveLiveAndPersistedSnapshotsUnchanged() throws {
        let (fixture, store, _) = try fixture()
        defer { store.flushPendingSessionSaves() }
        let before = store.sessions.map(\.persistenceSnapshot)
        let persisted = fixture.persistence.load()
        for (source, parent) in [
            ("source", "source"), ("source", "child"), ("source", "leaf"),
            ("source", "missing"), ("source", "closed"), ("source", "foreign"),
            ("missing", "target"), ("closed", "target"), ("closed", "")
        ] {
            #expect(throws: SessionReparentingError.self) { try store.reparent(id: source, parentSessionID: parent) }
            #expect(store.sessions.map(\.persistenceSnapshot) == before)
            store.flushPendingSessionSaves()
            #expect(fixture.persistence.load() == persisted)
        }
    }

    @Test func targetPickerIncludesHiddenHierarchyAndMoveKeepsVisibilityState() throws {
        let (_, store, _) = try fixture()
        defer { store.flushPendingSessionSaves() }
        store.collapsedParentIDs = ["target"]
        store.expandedParentIDs = ["old"]
        store.showFinishedChildren = false
        try session("hidden", in: store).status = .completed
        let targets = store.reparentTargets(for: "source")
        #expect(targets.map(\.id) == ["old", "target", "hidden"])
        #expect(targets.first { $0.id == "hidden" }?.depth == 1)
        #expect(!store.sessionSidebarGroups.flatMap(\.items).contains { $0.id == "hidden" })
        try store.reparent(id: "source", parentSessionID: "target")
        #expect(store.collapsedParentIDs == ["target"])
        #expect(store.expandedParentIDs == ["old"])
        #expect(store.selectedSessionID == nil)
        #expect(!store.showFinishedChildren)
        #expect(!store.sessionSidebarGroups.flatMap(\.items).contains { $0.id == "source" })
        try store.reparent(id: "source", parentSessionID: "hidden")
        #expect(try session("source", in: store).parentSessionID == "hidden")
        #expect(try session("child", in: store).parentSessionID == "source")
        #expect(store.collapsedParentIDs == ["target"])
        #expect(store.reparentTargets(for: "closed").isEmpty)
    }

    @Test func closeAndRemoveStillPromoteChildrenToNewParent() throws {
        for removing in [false, true] {
            let (_, store, _) = try fixture()
            defer { store.flushPendingSessionSaves() }
            try store.reparent(id: "source", parentSessionID: "target")
            if removing { try store.remove(id: "source") }
            else { try store.close(id: "source") }
            #expect(try session("child", in: store).parentSessionID == "target")
            #expect(try session("leaf", in: store).parentSessionID == "child")
            let rows = store.sessionSidebarGroups.flatMap(\.items)
            #expect(rows.first { $0.id == "child" }?.depth == 1)
            #expect(rows.first { $0.id == "leaf" }?.depth == 2)
            #expect(rows.filter { ["target", "child", "leaf", "hidden"].contains($0.id) }.map(\.id) == ["target", "child", "leaf", "hidden"])
        }
    }

    @Test func closingParentSelectsPromotedChildBeforeAnotherProject() throws {
        let (_, store, _) = try fixture()
        defer { store.flushPendingSessionSaves() }
        for id in ["target", "hidden"] {
            try session(id, in: store).status = .closed
        }
        for id in ["source", "child", "leaf"] {
            try session(id, in: store).status = .completed
        }
        store.showFinishedChildren = false
        store.selectedSessionID = "old"

        try store.close(id: "old")

        #expect(store.selectedSessionID == "source")
        #expect(try session("source", in: store).parentSessionID == nil)
    }

    @Test func httpMovesAndErrorsUseTheValidatedStoreOperation() async throws {
        let (fixture, store, _) = try fixture()
        let server = ControlServer(store: store, host: store.host, port: .any)
        server.start()
        defer { server.stop(); store.flushPendingSessionSaves() }
        try await waitForPuckState { server.listeningPort != nil }
        let before = fixture.persistence.load()
        for body in [
            ["id": "source", "parent": "leaf"], ["id": "source", "parent": "source"],
            ["id": "source", "parent": "missing"], ["id": "source", "parent": "closed"],
            ["id": "source", "parent": "foreign"], ["id": "missing"], ["id": "closed"],
            ["parent": "target"], ["id": "source", "parent": "target", "apiVersion": "v999"]
        ] {
            let (json, status) = try await post(body, server: server, store: store)
            #expect(status == 400)
            #expect(json["ok"] as? Bool == false)
            #expect((json["error"] as? [String: Any])?["message"] as? String != nil)
            store.flushPendingSessionSaves()
            #expect(fixture.persistence.load() == before)
        }
        for root in [["id": "source"], ["id": "source", "parent": ""], ["id": "source", "parent": NSNull()]] as [[String: Any]] {
            let (moved, moveStatus) = try await post(["id": "source", "parent": "target"], server: server, store: store)
            #expect(moveStatus == 200)
            let data = try #require(moved["data"] as? [String: Any])
            #expect((data["session"] as? [String: Any])?["parent"] as? String == "target")
            let (_, rootStatus) = try await post(root, server: server, store: store)
            #expect(rootStatus == 200)
            #expect(try session("source", in: store).parentSessionID == nil)
        }
    }

    @Test func compiledCLIMovesToParentAndRootWithoutEnvironmentInheritance() async throws {
        let (_, store, _) = try fixture()
        let server = ControlServer(store: store, host: store.host, port: .any)
        server.start()
        defer { server.stop(); store.flushPendingSessionSaves() }
        try await waitForPuckState { server.listeningPort != nil }
        let executable = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/debug/banyanctl")
        try #require(FileManager.default.isExecutableFile(atPath: executable.path))
        var environment = store.host.environment
        environment["BANYAN_FIXTURE_CONTROL_URL"] = "http://127.0.0.1:\(try #require(server.listeningPort))"
        environment["BANYAN_PARENT_SESSION_ID"] = "missing-inherited-parent"
        for (args, expected) in [(["--parent", "target"], "target" as String?), (["--no-parent"], nil)] {
            let result = try await SubprocessRunner.runAsync(arguments: [executable.path, "reparent", "--id", "source"] + args,
                cwd: store.host.currentDirectory, environment: environment, timeout: 8)
            #expect(result.terminationStatus == 0)
            let json = try #require(JSONSerialization.jsonObject(with: result.standardOutput) as? [String: Any])
            #expect(json["ok"] as? Bool == true)
            #expect(try session("source", in: store).parentSessionID == expected)
            #expect(try session("child", in: store).parentSessionID == "source")
            #expect(store.sessionSidebarGroups.flatMap(\.items).first { $0.id == "source" }?.depth == (expected == nil ? 0 : 1))
        }
        let invalid = try await SubprocessRunner.runAsync(arguments: [executable.path, "reparent", "--id", "source"],
            cwd: store.host.currentDirectory, environment: environment, timeout: 8)
        #expect(invalid.terminationStatus == 64)
    }

    private func post(_ body: [String: Any], server: ControlServer, store: SessionStore) async throws -> ([String: Any], Int?) {
        let port = try #require(server.listeningPort)
        var request = URLRequest(url: try #require(URL(string: "http://127.0.0.1:\(port)/reparent")))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(try ControlToken.loadOrCreate(environment: store.host.environment, homeDirectory: store.host.homeDirectory),
            forHTTPHeaderField: ControlToken.headerName)
        request.timeoutInterval = 5
        let (data, response) = try await URLSession.shared.data(for: request)
        return (try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]), (response as? HTTPURLResponse)?.statusCode)
    }
}
