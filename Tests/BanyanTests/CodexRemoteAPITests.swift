import Foundation
import Testing
@testable import Banyan
@testable import BanyanCore

@MainActor
private final class RemoteAPIServer: CodexThreadService {
    var calls: [String] = []
    func events() async -> AsyncStream<CodexAppServerEvent> { AsyncStream { _ in } }
    func setServerRequestHandler(_ handler: CodexAppServerClient.RequestHandler?) async {}
    func request(_ method: String, params: CodexJSONValue) async throws -> CodexJSONValue {
        calls.append(method)
        if method == "thread/unsubscribe" { return .object(["status": .string("unsubscribed")]) }
        if method == "turn/start" { return .object(["turn": .object(["id": .string("original-turn")])]) }
        return .object(["thread": .object(["id": params.objectValue?["threadId"] ?? .string("original-thread"),
            "status": .object(["type": .string("idle")])])])
    }
}

@Test @MainActor
func codexRemoteAuthenticatedHTTPListsOriginalIDsAndRejectsUnauthorizedContent() async throws {
    let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let service = RemoteAPIServer()
    let store = fixture.makeStore(codexService: service)
    store.enableNativeCodex = true
    let native = try await store.createCodexSession(cwd: fixture.project.path, id: "native")
    let server = ControlServer(store: store, host: store.host, port: .any)
    server.start()
    defer { server.stop() }
    try await waitForPuckState { server.listeningPort != nil }
    let port = try #require(server.listeningPort)
    let token = try ControlToken.loadOrCreate(environment: store.host.environment, homeDirectory: store.host.homeDirectory)
    func post(_ path: String, _ body: [String: Any], authorized: Bool = true) async throws -> (Int, [String: Any]) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authorized { request.setValue(token, forHTTPHeaderField: ControlToken.headerName) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as! HTTPURLResponse).statusCode, try JSONSerialization.jsonObject(with: data) as! [String: Any])
    }
    let principal = ["workspace": "T_TEST", "channel": "C_TEST", "user": "U_TEST"]
    let read: [String: Any] = ["action": "list", "principal": principal]
    #expect(try await post("/codex-remote", read, authorized: false).0 == 401)
    #expect(try await post("/codex-remote", read).0 == 403)
    #expect(try await post("/codex-remote-configure", ["enabled": true, "allowed": []]).0 == 200)
    #expect(try await post("/codex-remote", read).0 == 403)
    #expect(try await post("/codex-remote-configure", ["enabled": true, "allowed": [principal]]).0 == 200)
    let (status, result) = try await post("/codex-remote", read)
    #expect(status == 200)
    let session = ((result["data"] as? [String: Any])?["sessions"] as? [[String: Any]])?.first
    #expect(session?["sessionID"] as? String == native.id)
    #expect(session?["threadID"] as? String == native.agentSessionID)
    #expect(session?["context"] == nil)
    #expect(service.calls.filter { $0 == "thread/start" }.count == 1)
}
