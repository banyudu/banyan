import Foundation
import Testing
@testable import Banyan
@testable import BanyanCore

private actor DecisionContextFixture: TerminalConversationContextReading {
    var identity: SlackConversationIdentity
    private var remaining = 0
    private var held: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private var isHeld = false
    init(identity: SlackConversationIdentity) { self.identity = identity }
    func hold(afterReads: Int) { remaining = afterReads + 1; isHeld = false }
    func waitUntilHeld() async { if isHeld { return }; await withCheckedContinuation { started = $0 } }
    func release() { held?.resume(); held = nil }
    func read(sessionID: String, sessionName: String, provider: CodingAgentProvider?, earlier: String?,
              limit: Int, terminalOutput: Bool) async throws -> TerminalConversationContextReader.Context {
        if remaining > 0 {
            remaining -= 1
            if remaining == 0 {
                isHeld = true; started?.resume(); started = nil
                await withCheckedContinuation { held = $0 }
            }
        }
        return .init(source: .providerTranscript, conversationID: identity.conversationID, binding: identity,
              messages: [.init(role: "user", text: "Earlier context", truncated: false)], earlier: nil,
              output: nil, limitation: nil, truncated: false, mayBeStale: false)
    }
}

private final class DecisionPaneFixture: TmuxSessionStoreBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _text = "Bash command\n  echo fixture\n\n Do you want to proceed?\n ❯ 1. Yes\n   2. No\n Esc to cancel"
    private var _sent: [[TmuxKey]] = []
    private var _literal: [String] = []
    private var _failLiteral = false
    private var _mode = false
    private var _failAfterSend = false
    private var gate: DispatchSemaphore?
    private var entered = false
    var text: String { get { locked { _text } } set { locked { _text = newValue } } }
    var sent: [[TmuxKey]] { locked { _sent } }
    var literal: [String] { locked { _literal } }
    var failLiteral: Bool { get { locked { _failLiteral } } set { locked { _failLiteral = newValue } } }
    var inMode: Bool { get { locked { _mode } } set { locked { _mode = newValue } } }
    var failAfterSend: Bool { get { locked { _failAfterSend } } set { locked { _failAfterSend = newValue } } }
    var captureEntered: Bool { locked { entered } }
    func holdNextCapture() -> DispatchSemaphore {
        let value = DispatchSemaphore(value: 0)
        locked { gate = value; entered = false }
        return value
    }
    private func locked<T>(_ operation: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return operation() }
    func hasSession(named: String) -> Bool { true }
    func primaryPaneSnapshot(named: String) -> TmuxPaneSnapshot? {
        .init(paneID: "%1", rootPID: 100, currentCommand: "codex", currentPath: "/tmp", isDead: false, isInMode: inMode)
    }
    func captureVisibleText(paneID: String, lineLimit: Int) -> String {
        let wait = locked { () -> DispatchSemaphore? in
            let current = gate
            if current != nil { entered = true; gate = nil }
            return current
        }
        if let wait { _ = wait.wait(timeout: .now() + 5) }
        return text
    }
    func listBanyanSessions() -> [String] { [] }
    func ensureSession(named: String, cwd: String, command: String, banyanSessionID: String?) throws {}
    func killSession(named: String) {}
    func sendLiteral(paneID: String, text: String) throws {
        let fail = locked { () -> Bool in _literal.append(text); return _failLiteral }
        if fail { throw CocoaError(.fileWriteUnknown) }
    }
    func sendKeys(paneID: String, keys: [TmuxKey]) throws {
        let fail = locked { () -> Bool in _sent.append(keys); return _failAfterSend }
        if fail { throw CocoaError(.fileWriteUnknown) }
    }
}

private struct DecisionProcesses: ProcessTableProvider {
    func snapshot() -> ProcessTable {
        ProcessTable(rows: [.init(pid: 101, parentPID: 100, state: "S", elapsed: 5, commandName: "codex", arguments: "codex")])
    }
}

@Suite(.serialized)
@MainActor
struct SlackDecisionAPITests {
    private let principal = CodexRemotePrincipal(workspace: "T_TEST", channel: "C_TEST", user: "U_TEST")
    private let identity = SlackConversationIdentity(kind: "terminalCodex", conversationID: "thread", generation: "generation")

    private func fixture() throws -> (PuckStoreFixture, SessionStore, DecisionPaneFixture) {
        let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
        let now = Date()
        fixture.persistence.save([SessionSnapshot(id: "row", tmuxSessionName: "banyan-row", title: "Fixture",
            reportedTitle: nil, isTitlePinned: true, cwd: fixture.project.path, command: "codex", status: .closed,
            tone: .blue, createdAt: now, updatedAt: now)])
        let backend = DecisionPaneFixture()
        let store = fixture.makeStore(tmuxBackend: backend, processTable: DecisionProcesses())
        store.loadPersistedSessionsIfNeeded()
        try #require(store.sessions.first).status = .asking
        store.slackTerminalContext = DecisionContextFixture(identity: identity)
        try store.codexRemote.configure(.init(enabled: true, allowed: [principal]))
        _ = try store.slackThreadJournal.bind(sessionID: "row", identity: identity, principal: principal, slackThread: "100.1")
        return (fixture, store, backend)
    }

    private func request(_ action: String, extra: [String: Any] = [:]) throws -> SlackBrowserRequest {
        var object: [String: Any] = ["action": action, "principal": ["workspace": "T_TEST", "channel": "C_TEST", "user": "U_TEST"],
            "sessionID": "row", "slackThread": "100.1", "identity": ["kind": identity.kind,
            "conversationID": identity.conversationID, "generation": identity.generation]]
        object.merge(extra) { _, new in new }
        return try JSONDecoder().decode(SlackBrowserRequest.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @Test func awayCatchupIncludesCurrentDecisionWithoutTreatingAnIdleComposerAsOne() async throws {
        let (fixture, store, backend) = try fixture()
        defer { store.stopPuckObservation(); store.flushPendingSessionSaves(); try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await store.slackBrowser(request("awayConfigure", extra: ["followSessionID": "row", "follow": true]))
        let enabled = try await store.slackBrowser(request("awayConfigure", extra: ["awayEnabled": true]))
        let checkpoint = try #require(enabled["checkpointCursor"] as? Int)
        let snapshot = try await store.slackBrowser(request("awaySnapshot"))
        let decisions = try #require(snapshot["decisions"] as? [[String: Any]])
        #expect(decisions.count == 1 && decisions[0]["question"] as? String == "Do you want to proceed?")
        #expect(snapshot["startCursor"] as? Int == checkpoint)
        backend.text = "Finished.\n› Ask Codex to do anything\nGPT-6.1-Sol · Context 50%\n? for shortcuts"
        let current = try await store.slackBrowser(request("awaySnapshot"))
        #expect((current["decisions"] as? [[String: Any]])?.isEmpty == true)
        _ = try await store.slackBrowser(request("awayConfigure", extra: ["awayEnabled": false]))
        await #expect(throws: (any Error).self) { try await store.slackBrowser(request("awaySnapshot")) }
        #expect(try await store.slackBrowser(request("context"))["source"] as? String == "providerTranscript")
    }

    @Test func awaySnapshotReplaysEventsFromActivationBeforeCapture() async throws {
        let (fixture, store, _) = try fixture()
        defer { store.stopPuckObservation(); store.flushPendingSessionSaves(); try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await store.slackBrowser(request("awayConfigure", extra: ["followSessionID": "row", "follow": true]))
        let enabled = try await store.slackBrowser(request("awayConfigure", extra: ["awayEnabled": true]))
        let checkpoint = try #require(enabled["checkpointCursor"] as? Int)
        try #require(store.sessions.first).mark(status: .executing)
        let snapshot = try await store.slackBrowser(request("awaySnapshot"))
        let events = try #require(snapshot["events"] as? [[String: Any]])
        #expect(events.contains { $0["status"] as? String == "executing" && ($0["cursor"] as? Int ?? 0) > checkpoint })
        #expect(snapshot["startCursor"] as? Int == checkpoint)
    }

    @Test func changedPromptAtTheSameStatusEmitsOneScopedAwayEvent() async throws {
        let (fixture, store, _) = try fixture()
        defer { store.stopPuckObservation(); store.flushPendingSessionSaves(); try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await store.slackBrowser(request("awayConfigure", extra: ["followSessionID": "row", "follow": true]))
        let enabled = try await store.slackBrowser(request("awayConfigure", extra: ["awayEnabled": true]))
        let activation = try #require(enabled["activationID"] as? String)
        let cursor = store.sessionEvents(since: nil).cursor
        func observation(_ fingerprint: String?) -> SessionStatusObservation {
            .init(id: "row", status: .asking, tone: .yellow, provider: .codex, currentPath: fixture.project.path,
                  promptObserved: true, promptFootprint: fingerprint, promptActivationID: activation)
        }
        _ = store.applySupervisorResults([observation("first")])
        let first = store.sessionEvents(since: cursor)
        #expect(first.events.count == 1 && first.events[0].status == .asking)
        _ = store.applySupervisorResults([observation("first")])
        #expect(store.sessionEvents(since: first.cursor).events.isEmpty)
        _ = store.applySupervisorResults([observation("second")])
        let second = store.sessionEvents(since: first.cursor)
        #expect(second.events.count == 1 && second.events[0].previousStatus == .asking)
        _ = store.applySupervisorResults([observation(nil)])
        #expect(store.sessionEvents(since: second.cursor).events.count == 1)
        _ = try await store.slackBrowser(request("awayConfigure", extra: ["awayEnabled": false]))
        let offCursor = store.sessionEvents(since: nil).cursor
        _ = store.applySupervisorResults([observation("third")])
        #expect(store.sessionEvents(since: offCursor).events.isEmpty)
    }

    @Test func awaySnapshotIncludesTransitionsDuringCaptureAndDoesNotOfferResolvedDecision() async throws {
        let (fixture, store, backend) = try fixture()
        defer { store.stopPuckObservation(); store.flushPendingSessionSaves(); try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await store.slackBrowser(request("awayConfigure", extra: ["followSessionID": "row", "follow": true]))
        _ = try await store.slackBrowser(request("awayConfigure", extra: ["awayEnabled": true]))
        let gate = backend.holdNextCapture()
        defer { gate.signal() }
        let task = Task { try await store.slackBrowser(request("awaySnapshot")) }
        try await waitForPuckState { backend.captureEntered }
        backend.text = "Finished.\n› Ask Codex to do anything\nGPT-6.1-Sol · Context 50%\n? for shortcuts"
        try #require(store.sessions.first).mark(status: .executing)
        gate.signal()
        let snapshot = try await task.value
        #expect((snapshot["decisions"] as? [[String: Any]])?.isEmpty == true)
        let events = try #require(snapshot["events"] as? [[String: Any]])
        #expect(events.contains { $0["status"] as? String == "executing" })
        #expect(snapshot["gap"] as? Bool == false)
    }

    @Test func exactDecisionAnswerIsSubmittedOnceAndDesktopResolutionRetiresIt() async throws {
        let (fixture, store, backend) = try fixture()
        defer { store.stopPuckObservation(); store.flushPendingSessionSaves(); try? FileManager.default.removeItem(at: fixture.root) }
        let decision = try await store.slackBrowser(request("decision"))
        #expect(decision["question"] as? String == "Do you want to proceed?")
        #expect((decision["options"] as? [[String: Any]])?.compactMap { $0["label"] as? String } == ["Yes", "No"])
        #expect((decision["context"] as? [String])?.contains("echo fixture") == true)
        #expect(((decision["recentContext"] as? [[String: Any]])?.first)?["text"] as? String == "Earlier context")
        let id = try #require(decision["requestID"] as? String)
        let answer = try request("answer", extra: ["requestID": id, "operationID": "action-1", "option": 2])
        #expect(try await store.slackBrowser(answer)["status"] as? String == "submitted")
        #expect(backend.sent == [[.down, .enter]])
        #expect(try await store.slackBrowser(answer)["status"] as? String == "submitted")
        #expect(backend.sent.count == 1)
        backend.inMode = true
        #expect(try await store.slackBrowser(request("decision"))["status"] as? String == "unavailable")
        backend.inMode = false
        let stillAnswered = try await store.slackBrowser(request("decision"))
        #expect(stillAnswered["requestID"] as? String == id && stillAnswered["answerable"] as? Bool == false)
        let duplicate = try request("answer", extra: ["requestID": id, "operationID": "action-2", "option": 2])
        await #expect(throws: (any Error).self) { try await store.slackBrowser(duplicate) }
        backend.text = "Finished.\n› Ask Codex to do anything"
        let resolved = try await store.slackBrowser(request("decision"))
        #expect(resolved["status"] as? String == "resolved")
        await #expect(throws: (any Error).self) { try await store.slackBrowser(duplicate) }
        #expect(backend.sent.count == 1)
    }

    @Test func explicitFollowupSendsOnceOnlyToAnEmptyComposer() async throws {
        let (fixture, store, backend) = try fixture()
        defer { store.stopPuckObservation(); store.flushPendingSessionSaves(); try? FileManager.default.removeItem(at: fixture.root) }
        backend.text = "Finished.\n› Ask Codex to do anything\nGPT-6.1-Sol · Context 50%\n? for shortcuts"
        let reply = try request("followup", extra: ["operationID": "reply-1", "text": "Please continue"])
        #expect(try await store.slackBrowser(reply)["status"] as? String == "submitted")
        #expect(backend.literal == ["Please continue"] && backend.sent == [[.enter]])
        #expect(try await store.slackBrowser(reply)["status"] as? String == "submitted")
        #expect(backend.literal.count == 1 && backend.sent.count == 1)
        let invalid = try request("followup", extra: ["operationID": "reply-multiline", "text": "one\ntwo"])
        await #expect(throws: (any Error).self) { try await store.slackBrowser(invalid) }
        #expect(backend.literal.count == 1)
    }

    @Test func busyPickerAndDisabledInspectionRejectFollowupWithoutInput() async throws {
        let (fixture, store, backend) = try fixture()
        defer { store.stopPuckObservation(); store.flushPendingSessionSaves(); try? FileManager.default.removeItem(at: fixture.root) }
        let picker = try request("followup", extra: ["operationID": "reply-picker", "text": "continue"])
        #expect(try await store.slackBrowser(picker)["status"] as? String == "rejected")
        #expect(backend.literal.isEmpty && backend.sent.isEmpty)
        backend.text = "Finished.\n› Ask Codex to do anything\nGPT-6.1-Sol · Context 50%\n? for shortcuts"
        let gate = backend.holdNextCapture()
        defer { gate.signal() }
        let held = try request("followup", extra: ["operationID": "reply-held", "text": "continue"])
        let task = Task { try await store.slackBrowser(held) }
        try await waitForPuckState { backend.captureEntered }
        try store.codexRemote.configure(.init(enabled: false, allowed: [principal]))
        gate.signal()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(backend.literal.isEmpty && backend.sent.isEmpty)
    }

    @Test func uncertainFollowupBlocksLaterRepliesUntilLocalReconciliation() async throws {
        let (fixture, store, backend) = try fixture()
        defer { store.stopPuckObservation(); store.flushPendingSessionSaves(); try? FileManager.default.removeItem(at: fixture.root) }
        backend.text = "Finished.\n› Ask Codex to do anything\nGPT-6.1-Sol · Context 50%\n? for shortcuts"
        backend.failLiteral = true
        let reply = try request("followup", extra: ["operationID": "reply-uncertain", "text": "continue"])
        #expect(try await store.slackBrowser(reply)["status"] as? String == "uncertain")
        #expect(backend.literal == ["continue"] && backend.sent.isEmpty)
        #expect(try await store.slackBrowser(reply)["status"] as? String == "uncertain")
        let next = try request("followup", extra: ["operationID": "reply-next", "text": "another"])
        await #expect(throws: SlackFollowUpJournal.Failure.self) { try await store.slackBrowser(next) }
        #expect(backend.literal.count == 1)
        try store.slackFollowUpJournal.acknowledgeUncertain(operationID: "reply-uncertain", workspace: "T_TEST")
        #expect(try await store.slackBrowser(reply)["status"] as? String == "acknowledged")
        backend.failLiteral = false
        #expect(try await store.slackBrowser(next)["status"] as? String == "submitted")
        #expect(backend.literal == ["continue", "another"])
    }

    @Test func fakeSlackButtonReachesTheOwnedPaneThroughAuthenticatedHTTP() async throws {
        let (fixture, store, backend) = try fixture()
        defer { store.stopPuckObservation(); store.flushPendingSessionSaves(); try? FileManager.default.removeItem(at: fixture.root) }
        let server = ControlServer(store: store, host: store.host, port: .any)
        server.start()
        defer { server.stop() }
        try await waitForPuckState { server.listeningPort != nil }
        let port = try #require(server.listeningPort)
        let config: [String: Any] = ["controlURL": "http://127.0.0.1:\(port)",
            "tokenFile": ControlToken.tokenFileURL(environment: store.host.environment, homeDirectory: store.host.homeDirectory).path,
            "state": fixture.root.appendingPathComponent("connector.json").path]
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
        #expect(status == 0, "Fake Slack driver failed: \(String(decoding: data, as: UTF8.self))")
        #expect(backend.sent == [[.down, .enter]])
    }

    @Test func fakeSlackAwayCatchupIncludesAndAnswersAnExistingDecision() async throws {
        let (fixture, store, backend) = try fixture()
        defer { store.stopPuckObservation(); store.flushPendingSessionSaves(); try? FileManager.default.removeItem(at: fixture.root) }
        let server = ControlServer(store: store, host: store.host, port: .any)
        server.start()
        defer { server.stop() }
        try await waitForPuckState { server.listeningPort != nil }
        let port = try #require(server.listeningPort)
        let config: [String: Any] = ["controlURL": "http://127.0.0.1:\(port)",
            "tokenFile": ControlToken.tokenFileURL(environment: store.host.environment, homeDirectory: store.host.homeDirectory).path,
            "state": fixture.root.appendingPathComponent("connector.json").path, "mode": "away"]
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
        #expect(status == 0, "Fake Slack driver failed: \(String(decoding: data, as: UTF8.self))")
        #expect(backend.sent == [[.down, .enter]])
    }

    @Test func fakeSlackThreadReplyReachesTheOwnedPaneThroughAuthenticatedHTTP() async throws {
        let (fixture, store, backend) = try fixture()
        defer { store.stopPuckObservation(); store.flushPendingSessionSaves(); try? FileManager.default.removeItem(at: fixture.root) }
        backend.text = "Finished.\n› Ask Codex to do anything\nGPT-6.1-Sol · Context 50%\n? for shortcuts"
        let server = ControlServer(store: store, host: store.host, port: .any)
        server.start()
        defer { server.stop() }
        try await waitForPuckState { server.listeningPort != nil }
        let port = try #require(server.listeningPort)
        let config: [String: Any] = ["controlURL": "http://127.0.0.1:\(port)",
            "tokenFile": ControlToken.tokenFileURL(environment: store.host.environment, homeDirectory: store.host.homeDirectory).path,
            "state": fixture.root.appendingPathComponent("connector.json").path, "mode": "followup"]
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
        #expect(status == 0, "Fake Slack driver failed: \(String(decoding: data, as: UTF8.self))")
        #expect(backend.literal == ["Please continue"] && backend.sent == [[.enter]])
    }

    @Test func disablingDuringInspectionSendsNoKeys() async throws {
        let (fixture, store, backend) = try fixture()
        defer { store.stopPuckObservation(); store.flushPendingSessionSaves(); try? FileManager.default.removeItem(at: fixture.root) }
        let decision = try await store.slackBrowser(request("decision"))
        let id = try #require(decision["requestID"] as? String)
        let gate = backend.holdNextCapture()
        defer { gate.signal() }
        let answer = try request("answer", extra: ["requestID": id, "operationID": "action-held", "option": 1])
        let task = Task { try await store.slackBrowser(answer) }
        try await waitForPuckState { backend.captureEntered }
        try store.codexRemote.configure(.init(enabled: false, allowed: [principal]))
        gate.signal()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(backend.sent.isEmpty)
        let receipt = try #require(try store.slackDecisionJournal.receipt(operationID: "action-held", principal: principal))
        #expect(receipt.status == "rejected")
    }

    @Test func aResolvedRequestCannotSendAfterItsOldPromptReappears() async throws {
        let (fixture, store, backend) = try fixture()
        defer { store.stopPuckObservation(); store.flushPendingSessionSaves(); try? FileManager.default.removeItem(at: fixture.root) }
        let context = DecisionContextFixture(identity: identity)
        store.slackTerminalContext = context
        let decision = try await store.slackBrowser(request("decision"))
        let id = try #require(decision["requestID"] as? String)
        let original = backend.text
        await context.hold(afterReads: 1)
        let answer = try request("answer", extra: ["requestID": id, "operationID": "action-race", "option": 1])
        let task = Task { try await store.slackBrowser(answer) }
        await context.waitUntilHeld()
        backend.text = "Finished.\n› Ask Codex to do anything"
        #expect(try await store.slackBrowser(request("decision"))["status"] as? String == "resolved")
        backend.text = original
        await context.release()
        #expect(try await task.value["status"] as? String == "rejected")
        #expect(backend.sent.isEmpty)
    }

    @Test func uncertainDeliveryAndCopyModeNeverRepeatInput() async throws {
        let (fixture, store, backend) = try fixture()
        defer { store.stopPuckObservation(); store.flushPendingSessionSaves(); try? FileManager.default.removeItem(at: fixture.root) }
        backend.inMode = true
        #expect(try await store.slackBrowser(request("decision"))["status"] as? String == "unavailable")
        backend.inMode = false
        let decision = try await store.slackBrowser(request("decision"))
        let id = try #require(decision["requestID"] as? String)
        backend.failAfterSend = true
        let answer = try request("answer", extra: ["requestID": id, "operationID": "action-uncertain", "option": 1])
        #expect(try await store.slackBrowser(answer)["status"] as? String == "uncertain")
        #expect(backend.sent.count == 1)
        #expect(try await store.slackBrowser(answer)["status"] as? String == "uncertain")
        let other = try request("answer", extra: ["requestID": id, "operationID": "action-other", "option": 1])
        await #expect(throws: (any Error).self) { try await store.slackBrowser(other) }
        #expect(backend.sent.count == 1)
    }
}
