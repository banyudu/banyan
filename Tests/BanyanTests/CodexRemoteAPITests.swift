import Foundation
import Testing
@testable import Banyan
@testable import BanyanCore

@MainActor
private final class RemoteAPIServer: CodexThreadService {
    var calls: [String] = []
    var historyTurns: [CodexJSONValue] = []
    var home: String?
    var handler: CodexAppServerClient.RequestHandler?
    func storageHome() async -> String? { home }
    func events() async -> AsyncStream<CodexAppServerEvent> { AsyncStream { _ in } }
    func setServerRequestHandler(_ handler: CodexAppServerClient.RequestHandler?) async { self.handler = handler }
    func request(_ method: String, params: CodexJSONValue) async throws -> CodexJSONValue {
        calls.append(method)
        if method == "thread/unsubscribe" { return .object(["status": .string("unsubscribed")]) }
        if method == "turn/start" { return .object(["turn": .object(["id": .string("original-turn")])]) }
        return .object(["thread": .object(["id": params.objectValue?["threadId"] ?? .string("original-thread"),
            "turns": .array(method == "thread/read" ? historyTurns : []),
            "status": .object(["type": .string("idle")])])])
    }
}

@Test @MainActor
func slackNativeHistoryReadsExactTranscriptWithNativeToggleOff() async throws {
    let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let codexHome = fixture.root.appendingPathComponent("codex-home")
    let directory = codexHome.appendingPathComponent("sessions/2026/01/01")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("rollout-fixture-original-thread.jsonl")
    let lines = [#"{"type":"session_meta","payload":{"id":"original-thread"}}"#,
        #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"before away"}]}}"#,
        #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"answer"}]}}"#]
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
    let service = RemoteAPIServer(); service.home = codexHome.path
    let store = fixture.makeStore(codexService: service)
    defer { store.stopPuckObservation(); store.flushPendingSessionSaves() }
    store.enableNativeCodex = true
    let native = try await store.createCodexSession(cwd: fixture.project.path, id: "native")
    store.enableNativeCodex = false
    let principal = CodexRemotePrincipal(workspace: "T_TEST", channel: "C_TEST", user: "U_TEST")
    try store.codexRemote.configure(.init(enabled: true, allowed: [principal]))
    func request(_ cursor: String? = nil) throws -> SlackBrowserRequest {
        var body: [String: Any] = ["action": "context", "principal": ["workspace": "T_TEST", "channel": "C_TEST", "user": "U_TEST"],
            "sessionID": native.id, "limit": 1]
        if let cursor { body["cursor"] = cursor }
        return try JSONDecoder().decode(SlackBrowserRequest.self, from: JSONSerialization.data(withJSONObject: body))
    }
    service.calls.removeAll()
    let latest = try await store.slackBrowser(request())
    #expect(latest["source"] as? String == "providerTranscript")
    #expect(((latest["messages"] as? [[String: Any]])?.first)?["text"] as? String == "answer")
    let cursor = try #require(latest["earlier"] as? String)
    let earlier = try await store.slackBrowser(request(cursor))
    #expect(((earlier["messages"] as? [[String: Any]])?.first)?["text"] as? String == "before away")
    #expect(!service.calls.contains("thread/read") && !service.calls.contains("thread/resume") && !service.calls.contains("turn/start"))
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((#"{"type":"compacted","payload":{"replacement_history":[]}}"# + "\n").utf8))
    try handle.close()
    await #expect(throws: (any Error).self) { try await store.slackBrowser(request(cursor)) }
}

@Test func nativeTranscriptHistoryRejectsAmbiguousExactMatches() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("native_history_\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let sessions = root.appendingPathComponent("sessions")
    let archived = root.appendingPathComponent("archived_sessions")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
    let body = #"{"type":"session_meta","payload":{"id":"thread"}}"# + "\n"
    try Data(body.utf8).write(to: sessions.appendingPathComponent("rollout-first-thread.jsonl"))
    try Data(body.utf8).write(to: archived.appendingPathComponent("rollout-second-thread.jsonl"))
    let reader = SlackNativeTranscriptHistory()
    let page = try await reader.page(sessionID: "row", threadID: "thread", home: root.path, earlier: nil, limit: 10)
    #expect(page.map { _ in true } == nil)
}

@Test @MainActor
func fakeSlackAwayCatchupAnswersAnUnattachedNativeRequest() async throws {
    let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let service = RemoteAPIServer()
    let store = fixture.makeStore(codexService: service)
    defer { store.stopPuckObservation(); store.flushPendingSessionSaves() }
    store.enableNativeCodex = true
    let native = try await store.createCodexSession(cwd: fixture.project.path, id: "native")
    _ = try await store.codexThreads.startTurn(sessionID: native.id, input: [.object(["type": .string("text"), "text": .string("work")])])
    let handler = try #require(service.handler)
    let approval = CodexServerRequest(id: .string("approval-a"), method: "item/commandExecution/requestApproval",
        params: .object(["threadId": .string("original-thread"), "turnId": .string("original-turn"),
                         "command": .string("echo fixture"), "availableDecisions": .array([.string("accept"), .string("decline")])]))
    let pending = Task { await handler(approval) }
    try await waitForPuckState { native.state.pendingRequests.contains { $0.id == approval.id } }
    let principal = CodexRemotePrincipal(workspace: "T_TEST", channel: "C_TEST", user: "U_TEST")
    try store.codexRemote.configure(.init(enabled: true, allowed: [principal]))
    #expect(store.codexRemote.attachments.isEmpty)
    let server = ControlServer(store: store, host: store.host, port: .any)
    server.start(); defer { server.stop() }
    try await waitForPuckState { server.listeningPort != nil }
    let config: [String: Any] = ["controlURL": "http://127.0.0.1:\(try #require(server.listeningPort))",
        "tokenFile": ControlToken.tokenFileURL(environment: store.host.environment, homeDirectory: store.host.homeDirectory).path,
        "state": fixture.root.appendingPathComponent("connector.json").path, "mode": "native_away"]
    let input = fixture.root.appendingPathComponent("driver-input.json")
    try JSONSerialization.data(withJSONObject: config).write(to: input)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", "scripts/tests/slack_terminal_http_fixture.py", input.path]
    process.environment = ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
                           "HOME": fixture.home.path, "PYTHONDONTWRITEBYTECODE": "1"]
    let output = Pipe(); process.standardOutput = output; process.standardError = output
    let timeout = Task { @MainActor in
        try? await Task.sleep(for: .seconds(20))
        if process.isRunning { process.terminate() }
    }
    defer { timeout.cancel(); if process.isRunning { process.terminate() } }
    let status: Int32 = try await withCheckedThrowingContinuation { continuation in
        process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
        do { try process.run() } catch { continuation.resume(throwing: error) }
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    #expect(status == 0, "Fake Slack native driver failed: \(String(decoding: data, as: UTF8.self))")
    if status == 0 {
        if case .result(let result) = await pending.value { #expect(result.objectValue?["decision"] == .string("decline")) }
        else { Issue.record("Expected native approval result") }
    } else {
        native.respond(approval, decision: .decline)
        _ = await pending.value
    }
    #expect(service.calls.filter { $0 == "thread/start" }.count == 1)
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
    let terminalIdentity = SlackConversationIdentity(kind: "terminalCodex", conversationID: "terminal-thread", generation: "generation-a")
    _ = try store.slackThreadJournal.bind(sessionID: "terminal", identity: terminalIdentity,
        principal: .init(workspace: "T_TEST", channel: "C_TEST", user: "U_TEST"), slackThread: "100.123")
    let collision: [String: Any] = ["action": "attach", "principal": principal, "sessionID": native.id,
        "threadID": try #require(native.agentSessionID), "slackThread": "100.123"]
    #expect(try await post("/codex-remote", collision).0 == 409)
    #expect(store.codexRemote.attachments.isEmpty)
}

@Test @MainActor
func slackBrowserReadsNativeHistoryWithoutStartingOrResumingAThread() async throws {
    let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let service = RemoteAPIServer()
    service.historyTurns = [.object(["id": .string("turn-a"), "items": .array([
        .object(["id": .string("user-a"), "type": .string("userMessage"),
                 "content": .array([.object(["type": .string("text"), "text": .string("before away")])])]),
        .object(["id": .string("assistant-a"), "type": .string("agentMessage"), "text": .string("answer")])
    ])])]
    let store = fixture.makeStore(codexService: service)
    store.enableNativeCodex = true
    let native = try await store.createCodexSession(cwd: fixture.project.path, id: "native")
    let principal = CodexRemotePrincipal(workspace: "T_TEST", channel: "C_TEST", user: "U_TEST")
    try store.codexRemote.configure(.init(enabled: true, allowed: [principal]))
    let server = ControlServer(store: store, host: store.host, port: .any)
    server.start()
    defer { server.stop() }
    try await waitForPuckState { server.listeningPort != nil }
    let port = try #require(server.listeningPort)
    let token = try ControlToken.loadOrCreate(environment: store.host.environment, homeDirectory: store.host.homeDirectory)
    func post(cursor: String? = nil) async throws -> (Int, [String: Any]) {
        var request = URLRequest(url: try #require(URL(string: "http://127.0.0.1:\(port)/slack-browser")))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: ControlToken.headerName)
        var body: [String: Any] = ["action": "context", "principal": ["workspace": "T_TEST", "channel": "C_TEST", "user": "U_TEST"],
                                   "sessionID": native.id, "limit": 1]
        if let cursor { body["cursor"] = cursor }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        return (try #require((response as? HTTPURLResponse)?.statusCode),
                try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]))
    }
    service.calls.removeAll()
    let (status, first) = try await post()
    #expect(status == 200)
    let data = try #require(first["data"] as? [String: Any])
    #expect(data["source"] as? String == "nativeCodex")
    #expect(data["conversationID"] as? String == native.agentSessionID)
    #expect(((data["messages"] as? [[String: Any]])?.first)?["text"] as? String == "answer")
    let cursor = try #require(data["earlier"] as? String)
    let (_, earlier) = try await post(cursor: cursor)
    #expect((((earlier["data"] as? [String: Any])?["messages"] as? [[String: Any]])?.first)?["text"] as? String == "before away")
    #expect(service.calls == ["thread/read", "thread/read"])
    service.historyTurns = []
    let (changed, result) = try await post(cursor: cursor)
    #expect(changed == 409)
    #expect(result["data"] == nil)
    #expect(!service.calls.contains("thread/start") && !service.calls.contains("thread/resume") && !service.calls.contains("turn/start"))
}
