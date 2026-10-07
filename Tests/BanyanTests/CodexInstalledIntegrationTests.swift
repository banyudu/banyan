import AppKit
import Foundation
import SwiftUI
import Testing
import Vision
@testable import Banyan
@testable import BanyanCore

/// Opt in with scripts/verify-codex-integration.py. The model is deterministic;
/// the agent loop, tools, approvals, RPC, persistence, and view are real.
@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["BANYAN_CODEX_INTEGRATION_ROOT"] != nil))
func installedCodexNativeIntegration() async throws {
    let environment = ProcessInfo.processInfo.environment
    let root = URL(fileURLWithPath: try #require(environment["BANYAN_CODEX_INTEGRATION_ROOT"]))
    let executable = try #require(environment["BANYAN_CODEX_INTEGRATION_EXECUTABLE"])
    let home = root.appendingPathComponent("codex-home")
    let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let firstCWD = root.appendingPathComponent("workspace-a")
    try FileManager.default.createDirectory(at: firstCWD, withIntermediateDirectories: true)
    let childEnvironment = ["PATH": environment["PATH"] ?? "/usr/bin:/bin", "HOME": home.path,
        "CODEX_HOME": home.path, "TERM": "xterm-256color", "NO_COLOR": "1"]
    let client = CodexAppServerClient(executable: executable, environment: childEnvironment, requestTimeout: 15)
    let service = IntegratedCodexService(client: client, root: root)
    var observed: [String] = []
    let stream = await client.events()
    let observation = Task { @MainActor in
        for await event in stream {
            if case .notification(let method, _) = event { observed.append(method) }
        }
    }
    defer { observation.cancel() }
    do {
        let store = fixture.makeStore(codexService: service)
        store.enableNativeCodex = true
        let firstSettings = CodexThreadSettings(model: "fixture-model", modelProvider: "loopback",
            approvalPolicy: "untrusted", sandbox: "workspace-write",
            config: ["model_reasoning_effort": .string("low")])
        let first = try await store.createCodexSession(settings: firstSettings, cwd: firstCWD.path, id: "first")
        let firstID = try #require(first.agentSessionID)
        #expect(store.terminalSessions.isEmpty)
        do {
            try await store.freezeAgent(id: first.id)
            Issue.record("Native Codex must stay outside terminal process freezing")
        } catch { #expect(error.localizedDescription.contains("terminal agent session")) }
        try await send("fixture:hello", to: first)
        #expect(first.conversation.turns.last?.items.contains { $0.text == "FIXTURE_HELLO_OK" } == true)
        #expect(observed.contains("item/agentMessage/delta"))

        let secondCWD = root.appendingPathComponent("workspace-b")
        try FileManager.default.createDirectory(at: secondCWD, withIntermediateDirectories: true)
        let secondSettings = CodexThreadSettings(model: "fixture-second", modelProvider: "loopback_second",
            approvalPolicy: "never", sandbox: "read-only",
            config: ["model_reasoning_effort": .string("high")])
        let second = try await store.createCodexSession(settings: secondSettings, cwd: secondCWD.path, id: "second")
        let secondID = try #require(second.agentSessionID)
        try await send("fixture:second", to: second)
        #expect(firstID != secondID && first.cwd != second.cwd)
        #expect(first.state.connection == .unsubscribed)
        #expect(first.state.runtime.type == "idle") // Unsubscribe is not unload.
        #expect(first.conversation.turns.isEmpty)
        let loaded = try await client.request("thread/loaded/list")
        #expect(Set(loaded.objectValue?["data"]?.arrayValue.compactMap(\.stringValue) ?? []) == [firstID, secondID])
        #expect(try launches(root).count == 1) // Both native rows use one owned child.

        store.selectedSessionID = first.id
        try await store.codexThreads.select(sessionID: first.id)
        #expect(first.conversation.turns.last?.items.contains { $0.text == "FIXTURE_HELLO_OK" } == true)
        first.draft = "fixture:approve"
        await first.sendDraft()
        try #require(first.actionError == nil)
        try await waitForPuckState(timeout: .seconds(15)) { !first.state.pendingRequests.isEmpty }
        let approval = try #require(first.state.pendingRequests.first)
        try JSONEncoder().encode(approval.params).write(to: root.appendingPathComponent("approval-request.json"))
        #expect(approval.method == "item/commandExecution/requestApproval")
        #expect(approval.params.objectValue?["threadId"] == .string(firstID))
        #expect(approval.params.objectValue?["cwd"] == .string(firstCWD.path))
        #expect(!FileManager.default.fileExists(atPath: firstCWD.appendingPathComponent("approve-proof.txt").path))
        // Selection cannot move the pending request to another native row.
        store.selectedSessionID = second.id
        try await store.codexThreads.select(sessionID: second.id)
        #expect(first.state.isSubscribed && first.state.needsAttention)
        #expect(second.state.pendingRequests.isEmpty)
        try await render(first, store: store, root: root, name: "approval", expected: ["Cancel Turn", "Approve Once", "inactivity grace period"])
        first.respond(approval, decision: .accept)
        try #require(first.actionError == nil)
        try await waitForPuckState(timeout: .seconds(15)) { first.state.lastTurnStatus == "completed" }
        #expect(try String(contentsOf: firstCWD.appendingPathComponent("approve-proof.txt"), encoding: .utf8) == "APPROVED")
        try await waitForPuckState { first.state.connection == .unsubscribed }
        store.selectedSessionID = first.id
        try await store.codexThreads.select(sessionID: first.id)
        #expect(first.conversation.turns.flatMap(\.items).contains { $0.type == "commandExecution" && $0.isComplete })
        #expect(observed.contains("serverRequest/resolved"))

        first.draft = "fixture:decline"
        await first.sendDraft()
        try await waitForPuckState(timeout: .seconds(15)) { !first.state.pendingRequests.isEmpty }
        let refused = try #require(first.state.pendingRequests.first)
        let decision: CodexApprovalDecision = CodexConversationRequest(refused).decisions.contains(.decline) ? .decline : .cancel
        first.respond(refused, decision: decision)
        try #require(first.actionError == nil)
        try await waitForPuckState(timeout: .seconds(15)) { ["completed", "interrupted"].contains(first.state.lastTurnStatus ?? "") }
        #expect(!FileManager.default.fileExists(atPath: firstCWD.appendingPathComponent("decline-proof.txt").path))

        first.draft = "fixture:question"
        await first.sendDraft()
        try await waitForPuckState(timeout: .seconds(15)) { !first.state.pendingRequests.isEmpty }
        let question = try #require(first.state.pendingRequests.first)
        #expect(question.method == "item/tool/requestUserInput")
        try await render(first, store: store, root: root, name: "input", expected: ["Choose a fixture answer", "Alpha"])
        first.answer(question, answers: ["choice": "Alpha"])
        try #require(first.actionError == nil)
        try await waitForPuckState(timeout: .seconds(15)) { first.state.lastTurnStatus == "completed" }

        first.draft = "fixture:steer"
        await first.sendDraft()
        try await waitForPuckState(timeout: .seconds(15)) { first.conversation.turns.last?.items.contains { $0.text.contains("WORKING") } == true }
        let steeredTurn = try #require(first.state.activeTurnID)
        first.draft = "fixture:steered"
        await first.sendDraft()
        try #require(first.actionError == nil)
        try Data().write(to: root.appendingPathComponent("release-steer"))
        try await waitForPuckState(timeout: .seconds(15)) { first.state.lastTurnStatus == "completed" }
        #expect(first.conversation.turns.contains { $0.id == steeredTurn })
        try FileManager.default.removeItem(at: root.appendingPathComponent("release-steer"))
        first.draft = "fixture:interrupt"
        await first.sendDraft()
        try #require(first.actionError == nil)
        let interruptedTurn = try #require(first.state.activeTurnID)
        try await waitForPuckState(timeout: .seconds(15)) {
            first.conversation.turns.first { $0.id == interruptedTurn }?.items.contains { $0.text.contains("WORKING") } == true
        }
        await first.interrupt()
        try #require(first.actionError == nil)
        try await waitForPuckState(timeout: .seconds(15)) { first.state.lastTurnStatus == "interrupted" }

        await store.codexThreads.flushPersistence?()
        let snapshots = fixture.persistence.load()
        #expect(snapshots.first { $0.id == "first" }?.codex?.threadID == firstID)
        #expect(snapshots.first { $0.id == "first" }?.codex?.settings == firstSettings)
        #expect(snapshots.first { $0.id == "second" }?.codex?.settings == secondSettings)
        // Reap only this client's child, then restore a fresh SessionStore/client
        // from the same private SQLite DB. Exact IDs/settings must survive both.
        await client.stop()
        let replacement = CodexAppServerClient(executable: executable, environment: childEnvironment, requestTimeout: 15)
        do {
            let restored = fixture.makeStore(codexService: replacement)
            restored.loadPersistedSessionsIfNeeded()
            let row = try #require(restored.sessions.first { $0.id == "first" } as? CodexSession)
            let other = try #require(restored.sessions.first { $0.id == "second" } as? CodexSession)
            restored.selectedSessionID = row.id
            try await waitForPuckState { row.state.connection == .subscribed && restored.codexThreads.selectedSessionID == row.id }
            #expect(row.agentSessionID == firstID && row.cwd == firstCWD.path)
            #expect(row.state.binding.settings == firstSettings)
            #expect(row.conversation.turns.contains { $0.status == "completed" })
            try await send("fixture:hello-after-restart", to: row)
            try await render(row, store: restored, root: root, name: "restored", expected: ["FIXTURE_HELLO_OK", "Message Codex"])
            restored.selectedSessionID = other.id
            try await waitForPuckState { other.state.connection == .subscribed && restored.codexThreads.selectedSessionID == other.id }
            #expect(other.agentSessionID == secondID && other.cwd == secondCWD.path)
            #expect(other.state.binding.settings == secondSettings)
            try await send("fixture:second-after-restart", to: other)
            #expect(try launches(root).count == 2)
            do {
                _ = try await restored.fallbackCodexSessionToCLI(id: row.id)
                Issue.record("Expected CLI to reject retired untrusted config")
            } catch {
                #expect(error.localizedDescription.contains("untrusted"))
                #expect(error.localizedDescription.contains("native session is unchanged"))
            }
            #expect(restored.sessions.first { $0.id == row.id } === row)
            #expect(row.state.binding.settings == firstSettings)
            #expect(other.state.isSubscribed) // Failed preflight did not reap siblings.
            restored.selectedSessionID = row.id
            try await waitForPuckState { row.state.connection == .subscribed && restored.codexThreads.selectedSessionID == row.id }
            try await send("fixture:hello-after-refusal", to: row)
            // Park before handoff so SessionStore changes the real row without
            // opening a terminal or touching even the test tmux server.
            try restored.suspend(id: other.id)
            let terminal = try await restored.fallbackCodexSessionToCLI(id: other.id)
            #expect(terminal.id == other.id && terminal.agentSessionID == secondID)
            #expect(terminal.nativeCodexProvenance?.settings == secondSettings)
            let handoff: CodexJSONValue = .object([
                "command": .string(terminal.command), "cwd": .string(terminal.cwd),
                "threadID": .string(secondID), "codexHome": .string(home.path),
                "readyText": .string("FIXTURE_SECOND_OK")
            ])
            try JSONEncoder().encode(handoff).write(to: root.appendingPathComponent("handoff.json"), options: .atomic)
            let resultPath = root.appendingPathComponent("cli-result.json")
            try await waitForPuckState(timeout: .seconds(40)) { FileManager.default.fileExists(atPath: resultPath.path) }
            let cli = try JSONDecoder().decode(CodexJSONValue.self, from: Data(contentsOf: resultPath))
            #expect(cli.objectValue?["completed"] == .bool(true), "CLI handoff failed: \(cli.inspectableText)")
            #expect(try launches(root).count == 2) // Handoff did not restart the owned server.
        } catch {
            await replacement.stop()
            throw error
        }
        await replacement.stop()
        try await measureNativeIdleSessions(root: root, executable: executable, environment: childEnvironment)
        try JSONEncoder().encode(observed).write(to: root.appendingPathComponent("events.json"))
    } catch {
        await client.stop()
        throw error
    }
    await client.stop()
}

@MainActor
private func measureNativeIdleSessions(root: URL, executable: String, environment: [String: String]) async throws {
    let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let client = CodexAppServerClient(executable: executable, environment: environment)
    do {
        let store = fixture.makeStore(codexService: client)
        store.enableNativeCodex = true
        var cwds: [CodexJSONValue] = []
        var lastUnsubscribe = Date()
        for count in 1...4 {
            let cwd = root.appendingPathComponent("idle-\(count)")
            try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
            _ = try await store.createCodexSession(settings: .init(model: "fixture-model", modelProvider: "loopback",
                approvalPolicy: "never", sandbox: "read-only"), cwd: cwd.path, id: "idle-\(count)", select: false)
            lastUnsubscribe = Date()
            cwds.append(.string(cwd.path))
            guard [1, 2, 4].contains(count) else { continue }
            let loaded = try await client.request("thread/loaded/list")
            #expect(loaded.objectValue?["data"]?.arrayValue.count == count)
            #expect(store.sessions.allSatisfy { ($0 as? CodexSession)?.state.connection == .unsubscribed })
            let request: CodexJSONValue = .object(["count": .integer(Int64(count)), "cwds": .array(cwds)])
            try JSONEncoder().encode(request).write(to: root.appendingPathComponent("memory-request-\(count).json"), options: .atomic)
            let result = root.appendingPathComponent("memory-result-\(count).json")
            try await waitForPuckState(timeout: .seconds(50)) { FileManager.default.fileExists(atPath: result.path) }
            let sample = try JSONDecoder().decode(CodexJSONValue.self, from: Data(contentsOf: result))
            try #require(sample.objectValue?["error"] == nil, "RSS comparison failed: \(sample.inspectableText)")
        }
        // A second independently owned server can coexist on the same machine;
        // each client uses private pipes, with no socket name or live daemon.
        var sideEnvironment = environment
        let sideHome = root.appendingPathComponent("sidecar-home")
        try FileManager.default.createDirectory(at: sideHome, withIntermediateDirectories: true)
        sideEnvironment["CODEX_HOME"] = sideHome.path
        sideEnvironment["HOME"] = sideHome.path
        let sidecar = CodexAppServerClient(executable: executable, environment: sideEnvironment)
        do {
            try await sidecar.connect()
            let original = try await client.request("thread/loaded/list")
            let separate = try await sidecar.request("thread/loaded/list")
            #expect(original.objectValue?["data"]?.arrayValue.count == 4)
            #expect(separate.objectValue?["data"]?.arrayValue.isEmpty == true)
        } catch {
            await sidecar.stop()
            throw error
        }
        await sidecar.stop()
        let timeout = Int(ProcessInfo.processInfo.environment["BANYAN_CODEX_UNLOAD_TIMEOUT"] ?? "125") ?? 125
        try await waitForPuckState(timeout: .seconds(timeout)) {
            store.codexThreads.states.values.allSatisfy { $0.runtime.type == "notLoaded" && !$0.isSubscribed }
        }
        let unloaded: CodexJSONValue = .object([
            "threads": .integer(4), "allUnloaded": .bool(true),
            "elapsedAfterLastUnsubscribeMs": .integer(Int64(Date().timeIntervalSince(lastUnsubscribe) * 1000))
        ])
        try JSONEncoder().encode(unloaded).write(to: root.appendingPathComponent("native-unload.json"))
    } catch {
        await client.stop()
        throw error
    }
    await client.stop()
}

private func launches(_ root: URL) throws -> [Substring] {
    try String(contentsOf: root.appendingPathComponent("launches.jsonl"), encoding: .utf8).split(separator: "\n")
        .filter { $0.contains("app-server") }
}

private actor IntegratedCodexService: CodexThreadService {
    let client: CodexAppServerClient
    let root: URL
    var calls: [CodexJSONValue] = []

    init(client: CodexAppServerClient, root: URL) { self.client = client; self.root = root }
    func connect() async throws { try await client.connect() }
    func storageHome() async -> String? { await client.storageHome() }
    func disconnectForHandoff() async throws { try await client.disconnectForHandoff() }
    func validateCLIFallback(binding: CodexThreadBinding) async throws { try await client.validateCLIFallback(binding: binding) }
    func events() async -> AsyncStream<CodexAppServerEvent> { await client.events() }
    func setServerRequestHandler(_ handler: CodexAppServerClient.RequestHandler?) async {
        await client.setServerRequestHandler(handler)
    }
    func request(_ method: String, params: CodexJSONValue) async throws -> CodexJSONValue {
        let response = try await client.request(method, params: params)
        calls.append(.object(["method": .string(method), "params": params, "result": response]))
        try JSONEncoder().encode(calls).write(to: root.appendingPathComponent("rpc.json"))
        return response
    }
    func requestWhileConnected(_ method: String, params: CodexJSONValue) async throws -> CodexJSONValue {
        try await client.requestWhileConnected(method, params: params)
    }
}

@MainActor
private func send(_ text: String, to session: CodexSession) async throws {
    session.draft = text
    try #require(session.canSend)
    await session.sendDraft()
    try #require(session.actionError == nil)
    try await waitForPuckState(timeout: .seconds(15)) { session.state.lastTurnStatus == "completed" }
}

@MainActor
private func render(_ session: CodexSession, store: SessionStore, root: URL, name: String, expected: [String]) async throws {
    let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 980, height: 1000),
        styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let view = NSHostingView(rootView: CodexSessionDetail(session: session).environmentObject(store))
    window.contentView = view
    view.frame = NSRect(x: 0, y: 0, width: 980, height: 1000)
    try await Task.sleep(for: .milliseconds(250))
    view.layoutSubtreeIfNeeded()
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    try png.write(to: root.appendingPathComponent(name + ".png"))
    let text = try await Task.detached {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(data: png).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }.value
    try text.write(to: root.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
    for value in expected { #expect(text.contains(value), "Missing rendered text: \(value)") }
}
