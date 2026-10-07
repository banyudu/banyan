import Foundation
import Testing
@testable import Banyan
@testable import BanyanCore

/// scripts/verify-codex-integration.py --slack runs fake Slack through the REAL
/// authenticated HTTP server, SessionStore/coordinator and installed App Server.
@Test(.enabled(if: ProcessInfo.processInfo.environment["BANYAN_CODEX_SLACK_INTEGRATION"] == "1"))
@MainActor
func installedCodexSlackIntegration() async throws {
    let environment = ProcessInfo.processInfo.environment
    let root = URL(fileURLWithPath: try #require(environment["BANYAN_CODEX_INTEGRATION_ROOT"]))
    let home = root.appendingPathComponent("codex-home")
    let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let cwd = root.appendingPathComponent("workspace-slack")
    try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
    let client = CodexAppServerClient(executable: try #require(environment["BANYAN_CODEX_INTEGRATION_EXECUTABLE"]),
        environment: ["PATH": environment["PATH"] ?? "/usr/bin:/bin", "HOME": home.path,
            "CODEX_HOME": home.path, "TERM": "xterm-256color", "NO_COLOR": "1"], requestTimeout: 15)
    let service = SlackInstalledService(client: client)
    do {
        let store = fixture.makeStore(codexService: service)
        store.enableNativeCodex = true
        let settings = CodexThreadSettings(model: "fixture-model", modelProvider: "loopback",
            approvalPolicy: "untrusted", sandbox: "workspace-write", config: ["model_reasoning_effort": .string("low")])
        let native = try await store.createCodexSession(settings: settings, cwd: cwd.path, id: "native")
        // Persist an initial rollout so genuine unsubscribe/resume is available.
        native.draft = "fixture:hello-initial"
        await native.sendDraft()
        try #require(native.actionError == nil)
        try await waitForPuckState(timeout: .seconds(15)) { native.state.lastTurnStatus == "completed" }
        let originalThreadID = try #require(native.agentSessionID)
        let other = try await store.createCodexSession(settings: settings, cwd: cwd.path, id: "other")
        let originalSettings = native.state.binding.settings
        var desktopSawFollowup = false, desktopSawQuestionResult = false
        let desktopEvidence = store.codexThreads.observe(.init(event: { _, _, _ in
            desktopSawFollowup = desktopSawFollowup || native.conversation.turns.contains { turn in
                turn.items.contains { $0.text == "fixture:slack-followup" }
            }
            desktopSawQuestionResult = desktopSawQuestionResult || native.conversation.turns.contains { turn in
                turn.items.contains { $0.text.contains("FIXTURE_QUESTION_OK") }
            }
        }))
        defer { store.codexThreads.removeObserver(desktopEvidence) }
        let principal = CodexRemotePrincipal(workspace: "T_TEST", channel: "C_TEST", user: "U_TEST")
        try store.codexRemote.configure(.init(enabled: true, allowed: [principal]))
        let server = ControlServer(store: store, host: store.host, port: .any)
        server.start()
        defer { server.stop() }
        try await waitForPuckState { server.listeningPort != nil }
        let port = try #require(server.listeningPort)
        let request: [String: Any] = ["controlURL": "http://127.0.0.1:\(port)",
            "tokenFile": ControlToken.tokenFileURL(environment: store.host.environment, homeDirectory: store.host.homeDirectory).path,
            "root": root.path, "cwd": cwd.path, "threadID": originalThreadID]
        let input = root.appendingPathComponent("slack-driver-input.json")
        try JSONSerialization.data(withJSONObject: request).write(to: input)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "scripts/slack-integration-fixture.py", input.path]
        process.environment = ["PATH": environment["PATH"] ?? "/usr/bin:/bin", "HOME": fixture.home.path, "PYTHONDONTWRITEBYTECODE": "1"]
        let output = Pipe()
        process.standardOutput = output; process.standardError = output
        let timeout = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(110)) } catch { return }
            if process.isRunning { process.terminate() }
        }
        defer { timeout.cancel(); if process.isRunning { process.terminate() } }
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { p in continuation.resume(returning: p.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        try data.write(to: root.appendingPathComponent("slack-driver.log"))
        #expect(status == 0, "Fake Slack driver failed: \(String(decoding: data, as: UTF8.self))")
        #expect(native.agentSessionID == originalThreadID)
        #expect(native.state.binding.settings == originalSettings)
        #expect(native.cwd == cwd.path && FileManager.default.fileExists(atPath: cwd.path))
        #expect(store.selectedSessionID == other.id)
        #expect(desktopSawFollowup)
        #expect(desktopSawQuestionResult)
        #expect(service.calls.filter { $0.0 == "thread/start" }.count == 2) // Desktop-created rows only.
        #expect(service.calls.filter { $0.0 == "turn/start" && $0.1.objectValue?["threadId"] == .string(originalThreadID) }.count == 7)
        let prompts = service.calls.filter { $0.0 == "turn/start" && $0.1.objectValue?["threadId"] == .string(originalThreadID) }
            .map { $0.1.objectValue?["input"]?.arrayValue.first?.objectValue?["text"]?.stringValue }
        #expect(prompts == ["fixture:hello-initial", "fixture:slack-followup", "fixture:approve", "fixture:question", "fixture:steer", "fixture:interrupt", "fixture:hello-queued"])
        #expect(service.calls.filter { $0.0 == "turn/steer" }.count == 1)
        #expect(service.calls.filter { $0.0 == "turn/interrupt" }.count == 1)
        try JSONEncoder().encode(service.calls.map { call in CodexJSONValue.object(["method": .string(call.0), "params": call.1]) })
            .write(to: root.appendingPathComponent("slack-rpc.json"))
        await client.stop()
    } catch {
        await client.stop()
        throw error
    }
}

@MainActor
private final class SlackInstalledService: CodexThreadService {
    let client: CodexAppServerClient
    var calls: [(String, CodexJSONValue)] = []
    init(client: CodexAppServerClient) { self.client = client }
    func connect() async throws { try await client.connect() }
    func storageHome() async -> String? { await client.storageHome() }
    func events() async -> AsyncStream<CodexAppServerEvent> { await client.events() }
    func setServerRequestHandler(_ handler: CodexAppServerClient.RequestHandler?) async { await client.setServerRequestHandler(handler) }
    func request(_ method: String, params: CodexJSONValue) async throws -> CodexJSONValue {
        calls.append((method, params)); return try await client.request(method, params: params)
    }
}
