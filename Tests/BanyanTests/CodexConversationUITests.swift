import AppKit
import SwiftUI
import Vision
import Testing
@testable import Banyan
@testable import BanyanCore

@MainActor
private final class ConversationServer: CodexThreadService {
    var calls: [(String, CodexJSONValue)] = []
    var handler: CodexAppServerClient.RequestHandler?
    var stream: AsyncStream<CodexAppServerEvent>.Continuation?
    var starts = 0
    var failTurn = false
    var history: [String: CodexJSONValue] = [:]
    func events() async -> AsyncStream<CodexAppServerEvent> { AsyncStream { stream = $0 } }
    func setServerRequestHandler(_ handler: CodexAppServerClient.RequestHandler?) async { self.handler = handler }
    func request(_ method: String, params: CodexJSONValue) async throws -> CodexJSONValue {
        calls.append((method, params))
        if method == "turn/start", failTurn { throw CodexAppServerError.remote(code: -1, message: "Turn rejected") }
        if method == "turn/start" { return .object(["turn": .object(["id": .string("turn-1"), "status": .string("inProgress")])]) }
        if method == "turn/steer" { return .object(["turnId": params.objectValue?["expectedTurnId"] ?? .null]) }
        if method == "turn/interrupt" {
            emit("turn/completed", thread: params.objectValue?["threadId"]?.stringValue ?? "", turn: params.objectValue?["turnId"]?.stringValue ?? "",
                fields: ["turn": .object(["id": params.objectValue?["turnId"] ?? .null, "status": .string("interrupted")])])
            return .object([:])
        }
        if method == "thread/unsubscribe" { return .object(["status": .string("unsubscribed")]) }
        if method == "thread/start" { starts += 1 }
        if let id = params.objectValue?["threadId"]?.stringValue, let thread = history[id] {
            return .object(["thread": thread])
        }
        return .object(["thread": .object(["id": params.objectValue?["threadId"] ?? .string("thread-\(starts)"),
            "status": .object(["type": .string("idle")]), "turns": .array([])])])
    }
    func emit(_ method: String, thread: String = "thread-1", turn: String = "turn-1", fields: [String: CodexJSONValue]) {
        stream?.yield(.notification(method: method, params: .object(fields.merging([
            "threadId": .string(thread), "turnId": .string(turn)
        ]) { _, new in new })))
    }
}

@Suite(.serialized) @MainActor
struct CodexConversationUITests {
    @Test func nativeConversationDoesNotRetainLargeRawResumeHistory() async throws {
        let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
        let server = ConversationServer()
        let store = fixture.makeStore(codexService: server)
        let session = try await store.createCodexSession(cwd: fixture.project.path, id: "large-history", select: false)
        let threadID = try #require(session.state.binding.threadID)
        let turns: [CodexJSONValue] = (0..<300).map { index in
            .object(["id": .string("history-\(index)"), "status": .string("completed"), "items": .array([
                .object(["id": .string("message"), "type": .string("agentMessage"), "text": .string(String(repeating: "x", count: 8192))])])])
        }
        server.history[threadID] = .object(["id": .string(threadID), "status": .object(["type": .string("idle")]), "turns": .array(turns)])
        try await store.codexThreads.select(sessionID: session.id)
        #expect(session.state.connection == .subscribed)
        #expect(session.state.thread == nil)
        #expect(store.codexThreads.states[session.id]?.thread == nil)
        #expect(session.conversation.turns.count == CodexConversationBudget.turns)
        #expect(session.conversation.omittedTurns == 300 - CodexConversationBudget.turns)
        #expect(session.conversation.turns.last?.items.first?.text.count == 8192)
        // On-demand export/read still sees every authoritative server turn.
        let full = try await store.codexThreads.read(sessionID: session.id)
        #expect(full.objectValue?["thread"]?.objectValue?["turns"]?.arrayValue.count == 300)
        #expect(session.state.thread == nil && store.codexThreads.states[session.id]?.thread == nil)
    }

    @Test func nativeConversationReleasesVisitedHistoryAndRehydratesTheSameThread() async throws {
        let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
        let server = ConversationServer()
        let store = fixture.makeStore(codexService: server)
        var previous: CodexSession?
        var first: CodexSession?
        for index in 0..<12 {
            let session = try await store.createCodexSession(cwd: fixture.project.path, id: "visit-\(index)", select: false)
            let threadID = try #require(session.state.binding.threadID)
            let raw: CodexJSONValue = .object(["id": .string(threadID), "status": .object(["type": .string("idle")]),
                "turns": .array([.object(["id": .string("history"), "status": .string("completed"), "items": .array([
                    .object(["id": .string("message"), "type": .string("agentMessage"), "text": .string("Stored history \(index)")])])])])])
            server.history[threadID] = raw
            // Exercise subscription/cache ownership without starting unrelated
            // project metadata processes for every stress-test visit.
            try await store.codexThreads.select(sessionID: session.id)
            session.receive(method: "item/completed", params: .object(["threadId": .string(threadID), "turnId": .string("history"),
                "item": .object(["id": .string("message"), "type": .string("agentMessage"), "text": .string("Stored history \(index)")])]))
            session.draft = "Unsent draft \(index)"
            if let previous {
                try await waitForPuckState { previous.state.connection == .unsubscribed }
                #expect(previous.conversation.turns.isEmpty)
                #expect(previous.state.thread == nil)
                #expect(!previous.draft.isEmpty)
                previous.receive(method: "item/agentMessage/delta", params: .object([
                    "threadId": .string(previous.state.binding.threadID!), "turnId": .string("late"),
                    "itemId": .string("late"), "delta": .string("queued after unsubscribe")]))
                #expect(previous.conversation.turns.isEmpty)
            }
            if first == nil { first = session }
            previous = session
        }
        let revisited = try #require(first)
        let binding = revisited.state.binding
        try await store.codexThreads.select(sessionID: revisited.id)
        try await waitForPuckState { revisited.state.connection == .subscribed && !revisited.conversation.turns.isEmpty }
        #expect(revisited.state.binding == binding)
        #expect(revisited.conversation.turns[0].items[0].text == "Stored history 0")
        #expect(revisited.draft == "Unsent draft 0")
        #expect(server.starts == 12)
        let full = try await revisited.coordinator.read(sessionID: revisited.id)
        #expect(full.objectValue?["thread"] == server.history[binding.threadID!])
    }
    @Test func nativeConversationRoutesBackgroundStreamingAndKeepsDraftsOnFailure() async throws {
        let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
        let server = ConversationServer()
        let store = fixture.makeStore(codexService: server)
        let first = try await store.createCodexSession(settings: .init(approvalPolicy: "untrusted", sandbox: "read-only"), cwd: fixture.project.path, id: "first")
        first.draft = "Implement a feature"
        await first.sendDraft()
        #expect(first.draft.isEmpty)
        #expect(first.state.activeTurnID == "turn-1")
        let second = try await store.createCodexSession(cwd: fixture.project.path, id: "second")
        server.emit("item/agentMessage/delta", fields: ["itemId": .string("same-id"), "delta": .string("Background message")])
        server.emit("item/agentMessage/delta", thread: "thread-2", turn: "turn-2", fields: ["itemId": .string("same-id"), "delta": .string("Selected message")])
        try await waitForPuckState { first.conversation.turns.first?.items.first?.text == "Background message" && second.conversation.turns.first?.items.first?.text == "Selected message" }
        #expect(store.selectedSessionID == second.id)
        first.draft = "Focus on tests"
        await first.sendDraft()
        #expect(server.calls.last?.0 == "turn/steer")
        #expect(server.calls.last?.1.objectValue?["threadId"] == .string("thread-1"))
        #expect(server.calls.last?.1.objectValue?["expectedTurnId"] == .string("turn-1"))
        #expect(first.state.binding.settings.approvalPolicy == "untrusted")
        #expect(first.state.binding.settings.sandbox == "read-only")
        #expect(first.cwd == fixture.project.path)
        server.failTurn = true
        second.draft = "Keep this if rejected"
        await second.sendDraft()
        #expect(second.draft == "Keep this if rejected")
        #expect(second.actionError?.contains("Turn rejected") == true)
        await first.interrupt()
        try await waitForPuckState { first.state.lastTurnStatus == "interrupted" }
        #expect(first.state.activeTurnID == nil)
    }

    @Test func nativeConversationAnswersDeclinesAndCancelsRoutedRequests() async throws {
        let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
        let server = ConversationServer()
        let store = fixture.makeStore(codexService: server)
        let first = try await store.createCodexSession(cwd: fixture.project.path, id: "first")
        first.draft = "Start"
        await first.sendDraft()
        let second = try await store.createCodexSession(cwd: fixture.project.path, id: "second")
        let handler = try #require(server.handler)
        for (index, decision) in CodexApprovalDecision.allCases.enumerated() {
            let request = CodexServerRequest(id: .integer(Int64(index)),
                method: index.isMultiple(of: 2) ? "item/commandExecution/requestApproval" : "item/fileChange/requestApproval",
                params: .object(["threadId": .string("thread-1"), "turnId": .string("turn-1"),
                    "availableDecisions": .array(CodexApprovalDecision.allCases.map { .string($0.rawValue) })]))
            let answer = Task { await handler(request) }
            try await waitForPuckState { first.state.pendingRequests.contains { $0.id == request.id } }
            #expect(second.state.pendingRequests.isEmpty)
            // A request cannot be answered through another session.
            second.respond(request, decision: decision)
            #expect(second.actionError != nil)
            first.respond(request, decision: decision)
            if case .result(let reply) = await answer.value { #expect(reply == .object(["decision": .string(decision.rawValue)])) }
            else { Issue.record("Expected approval reply") }
            #expect(first.submittedRequestIDs.contains(request.id.inspectableText))
            #expect(first.state.pendingRequests.count == 1)
            server.emit("serverRequest/resolved", fields: ["requestId": request.id])
            try await waitForPuckState { first.state.pendingRequests.isEmpty }
            #expect(first.submittedRequestIDs.isEmpty)
        }
        let input = CodexServerRequest(id: .string("input"), method: "item/tool/requestUserInput", params: .object([
            "threadId": .string("thread-1"), "turnId": .string("turn-1"),
            "questions": .array([.object(["id": .string("answer-id"), "question": .string("Details?")])])]))
        let answer = Task { await handler(input) }
        try await waitForPuckState { first.state.pendingRequests.count == 1 }
        first.answer(input, answers: ["answer-id": "Details"])
        if case .result(let value) = await answer.value {
            #expect(value.objectValue?["answers"]?.objectValue?["answer-id"] == .object(["answers": .array([.string("Details")])]))
        } else { Issue.record("Expected input answer") }
        server.emit("serverRequest/resolved", fields: ["requestId": input.id])
        try await waitForPuckState { first.state.pendingRequests.isEmpty }
        let cancel = Task { await handler(input) }
        try await waitForPuckState { first.state.pendingRequests.count == 1 }
        await first.cancelInput(input)
        _ = await cancel.value
        try await waitForPuckState { first.state.pendingRequests.isEmpty && first.state.lastTurnStatus == "interrupted" }
        #expect(server.calls.last { $0.0 == "turn/interrupt" }?.1.objectValue?["threadId"] == .string("thread-1"))
    }

    @Test func nativeConversationRendersInAnIsolatedWindow() async throws {
        let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
        let server = ConversationServer()
        let store = fixture.makeStore(codexService: server)
        let session = try await store.createCodexSession(cwd: fixture.project.path, id: "render")
        session.receive(method: "item/completed", params: .object([
            "threadId": .string("thread-1"), "turnId": .string("turn-1"), "item": .object([
                "id": .string("reply"), "type": .string("agentMessage"), "text": .string("### Native Codex\nStreaming **Markdown** and command output.")])]))
        session.receive(method: "item/completed", params: .object([
            "threadId": .string("thread-1"), "turnId": .string("turn-1"), "item": .object([
                "id": .string("command"), "type": .string("commandExecution"), "command": .string("swift test"),
                "aggregatedOutput": .string("\u{1b}[32mAll tests passed\u{1b}[0m"), "exitCode": .integer(0), "status": .string("completed")])]))
        session.receive(method: "item/completed", params: .object([
            "threadId": .string("thread-1"), "turnId": .string("turn-1"), "item": .object([
                "id": .string("file"), "type": .string("fileChange"), "status": .string("completed"), "changes": .array([
                    .object(["path": .string("Sources/Example.swift"), "kind": .object(["type": .string("update")]), "diff": .string("@@ -1 +1 @@\n-old\n+new")])])])]))
        let request = CodexServerRequest(id: .string("render-approval"), method: "item/commandExecution/requestApproval", params: .object([
            "threadId": .string("thread-1"), "turnId": .string("turn-1"), "command": .string("swift test"), "reason": .string("Run project checks?")]))
        let handler = try #require(server.handler)
        let pending = Task { await handler(request) }
        try await waitForPuckState { session.state.pendingRequests.count == 1 }
        let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 980, height: 1000), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let hosting = NSHostingView(rootView: CodexSessionDetail(session: session).environmentObject(store))
        window.contentView = hosting
        hosting.frame = NSRect(x: 0, y: 0, width: 980, height: 1000)
        hosting.layoutSubtreeIfNeeded()
        // Let SwiftUI finish its initial layout without activating a live app.
        try await Task.sleep(for: .milliseconds(150))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(png.count > 5000)
        #expect(bitmap.colorAt(x: 50, y: 150)?.alphaComponent ?? 0 > 0.99)
        // A windowless test host doesn't build SwiftUI's live AX tree. Verify
        // actual visible content with native OCR, alongside pixel/layout QA.
        let recognized = try await recognize(png)
        #expect(recognized.contains("Open Shell"))
        #expect(recognized.contains("All tests passed"))
        #expect(recognized.contains("Example.swift"))
        #expect(recognized.contains("Decline"))
        #expect(recognized.contains("Message Codex"))
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BANYAN_CODEX_RENDER_DIR"] ?? NSTemporaryDirectory() + "banyan-codex-render")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent("conversation.png"))
        #expect(hosting.bounds.width == 980)
        // Rollout disable must explain why input is absent, while keeping
        // approval replies and interruption visible and preserving the draft.
        session.draft = "Preserve this draft"
        let callsBeforeDisable = server.calls.count
        hosting.rootView = CodexSessionDetail(session: session, nativeModeEnabled: false).environmentObject(store)
        try await Task.sleep(for: .milliseconds(150))
        hosting.layoutSubtreeIfNeeded()
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let disabledPNG = try #require(bitmap.representation(using: .png, properties: [:]))
        let disabledText = try await recognize(disabledPNG)
        #expect(disabledText.contains("Native Codex is disabled"))
        #expect(disabledText.contains("Interrupt"))
        #expect(disabledText.contains("Decline"))
        #expect(!disabledText.contains("Message Codex"))
        #expect(!disabledText.split(separator: "\n").contains("Send"))
        #expect(!disabledText.split(separator: "\n").contains("Steer"))
        #expect(session.draft == "Preserve this draft")
        #expect(server.calls.count == callsBeforeDisable)
        try disabledPNG.write(to: directory.appendingPathComponent("conversation-disabled.png"))
        session.respond(request, decision: .decline)
        _ = await pending.value
    }

    private func recognize(_ png: Data) async throws -> String {
        try await Task.detached {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(data: png).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        }.value
    }
}
