import Foundation
import Testing
@testable import Banyan
@testable import BanyanCore

@MainActor
@Suite(.serialized)
struct SessionListTransportTests {
    private func fixture() throws -> (PuckStoreFixture, SessionStore, ControlServer) {
        let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
        let now = Date()
        fixture.persistence.save(["active", "completed", "closed"].map { id in
            SessionSnapshot(id: id, tmuxSessionName: "banyan-\(id)",
                title: id == "closed" ? "Archived Widget & Notes" : id,
                reportedTitle: nil, isTitlePinned: true, cwd: fixture.project.path,
                command: "fixture-agent", status: .closed, tone: .blue,
                createdAt: now, updatedAt: now)
        })
        let store = fixture.makeStore(sessionBackend: AdmissionTerminalBackend())
        store.loadPersistedSessionsIfNeeded()
        try #require(store.sessions.first { $0.id == "active" }).status = .needInput
        try #require(store.sessions.first { $0.id == "completed" }).status = .completed
        let server = ControlServer(store: store, host: store.host, port: .any)
        server.start()
        return (fixture, store, server)
    }

    @Test func httpListsActiveDetailsAndCanSearchOrReadClosedHistory() async throws {
        let (_, store, server) = try fixture()
        defer { server.stop(); store.stopPuckObservation(); store.flushPendingSessionSaves() }
        try await waitForPuckState { server.listeningPort != nil }
        for (path, expected) in [
            ("/list", Set(["active", "completed"])),
            ("/list?all=true", Set(["active", "completed", "closed"])),
            ("/list?id=closed", Set(["closed"])),
            ("/list?id=close", Set<String>()),
            ("/list?query=widget", Set<String>()),
            ("/list?all=true&query=WIDGET%20%26%20NOTES", Set(["closed"]))
        ] {
            let (json, status) = try await get(path, store: store, server: server)
            #expect(status == 200)
            let data = try #require(json["data"] as? [String: Any])
            #expect(data["workflowProtocol"] as? Int == 1)
            let rows = try #require(data["sessions"] as? [[String: Any]])
            #expect(Set(rows.compactMap { $0["id"] as? String }) == expected)
            for row in rows {
                #expect(row["cwd"] as? String == store.host.currentDirectory)
                #expect(row["command"] as? String == "fixture-agent")
                #expect(row["updatedAt"] is String)
            }
        }
        let (_, status) = try await get("/list?all=invalid", store: store, server: server)
        #expect(status == 400)
    }

    @Test func compiledCLIForwardsFiltersAndKeepsUnifiedAndRawResponseShapes() async throws {
        let (fixture, store, server) = try fixture()
        defer { server.stop(); store.stopPuckObservation(); store.flushPendingSessionSaves() }
        try await waitForPuckState { server.listeningPort != nil }
        let executable = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/debug/banyanctl")
        try #require(FileManager.default.isExecutableFile(atPath: executable.path))
        var environment = store.host.environment
        environment["BANYAN_FIXTURE_CONTROL_URL"] = "http://127.0.0.1:\(try #require(server.listeningPort))"
        environment["PUCK_HOME"] = fixture.root.appendingPathComponent("no-daemon").path
        for (args, expected) in [
            (["list"], Set(["active", "completed"])),
            (["session", "list"], Set(["active", "completed"])),
            (["session", "list", "--all"], Set(["active", "completed", "closed"])),
            (["session", "list", "--id", "closed"], Set(["closed"])),
            (["list", "--all", "--query", "WIDGET & NOTES"], Set(["closed"])),
            (["session", "list", "--all", "--query", "WIDGET & NOTES"], Set(["closed"]))
        ] {
            let result = try await SubprocessRunner.runAsync(arguments: [executable.path] + args,
                cwd: store.host.currentDirectory, environment: environment, timeout: 8)
            #expect(result.terminationStatus == 0)
            let json = try #require(JSONSerialization.jsonObject(with: result.standardOutput) as? [String: Any])
            let data = args.first == "list" ? try #require(json["data"] as? [String: Any]) : json
            #expect(data["workflowProtocol"] as? Int == 1)
            let rows = try #require(data["sessions"] as? [[String: Any]])
            #expect(Set(rows.compactMap { $0["id"] as? String }) == expected)
        }
        let invalid = try await SubprocessRunner.runAsync(arguments: [executable.path, "session", "list", "--query"],
            cwd: store.host.currentDirectory, environment: environment, timeout: 8)
        #expect(invalid.terminationStatus == 64)
    }

    private func get(_ path: String, store: SessionStore, server: ControlServer) async throws -> ([String: Any], Int?) {
        let port = try #require(server.listeningPort)
        var request = URLRequest(url: try #require(URL(string: "http://127.0.0.1:\(port)\(path)")))
        let token = try ControlToken.loadOrCreate(environment: store.host.environment, homeDirectory: store.host.homeDirectory)
        request.setValue(token, forHTTPHeaderField: ControlToken.headerName)
        request.timeoutInterval = 5
        let (data, response) = try await URLSession.shared.data(for: request)
        return (try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]), (response as? HTTPURLResponse)?.statusCode)
    }
}
