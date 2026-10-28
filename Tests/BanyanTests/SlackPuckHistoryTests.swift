import Foundation
import Testing
@testable import Banyan
@testable import BanyanCore

private final class HeldFollowUpDispatch: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var entered = false
    var isEntered: Bool { lock.lock(); defer { lock.unlock() }; return entered }
    func wait() { lock.lock(); entered = true; lock.unlock(); _ = gate.wait(timeout: .now() + 5) }
    func release() { gate.signal() }
}

@Test @MainActor
func slackPuckHistoryReadsBoundedDaemonEventsWithoutStartingOrFollowing() async throws {
    let daemon = FakePuckDaemon()
    let fixture = try PuckStoreFixture(daemon: daemon)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let summary = puckSummary(id: "puck-fixture", cwd: fixture.project.path, historyItems: 2)
    daemon.put(summary, transcript: [
        .init(cursor: 1, kind: "text_delta", text: "hello "),
        .init(cursor: 2, kind: "text_delta", text: "world"),
        .init(cursor: 3, kind: "turn_done", text: "hello world"),
        .init(cursor: 4, kind: "tool_result", tool: "fixture", output: "result")
    ])
    let store = fixture.makeStore()
    defer { store.stopPuckObservation(); store.flushPendingSessionSaves() }
    store.applyPuckSummaries([summary])
    let principal = CodexRemotePrincipal(workspace: "T_TEST", channel: "C_TEST", user: "U_TEST")
    try store.codexRemote.configure(.init(enabled: true, allowed: [principal]))
    func request(_ cursor: String? = nil) throws -> SlackBrowserRequest {
        var object: [String: Any] = ["action": "context", "principal": ["workspace": "T_TEST", "channel": "C_TEST", "user": "U_TEST"],
                                     "sessionID": summary.id, "limit": 1]
        if let cursor { object["cursor"] = cursor }
        return try JSONDecoder().decode(SlackBrowserRequest.self, from: JSONSerialization.data(withJSONObject: object))
    }
    let latest = try await store.slackBrowser(request())
    #expect(latest["source"] as? String == "puckEvents")
    #expect((latest["limitation"] as? String)?.contains("omit user prompts") == true)
    #expect(((latest["messages"] as? [[String: Any]])?.first)?["text"] as? String == "fixture: result")
    let cursor = try #require(latest["earlier"] as? String)
    let earlier = try await store.slackBrowser(request(cursor))
    #expect(((earlier["messages"] as? [[String: Any]])?.first)?["text"] as? String == "hello world")
    #expect(daemon.turns.isEmpty && daemon.creations.isEmpty && !daemon.isFollowed(summary.id))
}

@Test @MainActor
func slackPuckHistoryUsesDaemonPagesWithoutStartingOrFollowing() async throws {
    let daemon = FakePuckDaemon()
    let fixture = try PuckStoreFixture(daemon: daemon)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let summary = puckSummary(id: "puck-fixture", cwd: fixture.project.path, historyItems: 3)
    daemon.put(summary)
    daemon.putHistoryPage(.init(session: summary.id, source: "native", items: [
        .init(id: "3", kind: "assistant", text: "answer"), .init(id: "2", kind: "user", text: "before away")], nextCursor: "older"))
    daemon.putHistoryPage(.init(session: summary.id, source: "native", items: [
        .init(id: "1", kind: "user", text: "earliest")], nextCursor: nil), cursor: "older")
    let store = fixture.makeStore()
    defer { store.stopPuckObservation(); store.flushPendingSessionSaves() }
    store.applyPuckSummaries([summary])
    let principal = CodexRemotePrincipal(workspace: "T_TEST", channel: "C_TEST", user: "U_TEST")
    try store.codexRemote.configure(.init(enabled: true, allowed: [principal]))
    func request(_ cursor: String? = nil) throws -> SlackBrowserRequest {
        var object: [String: Any] = ["action": "context", "principal": ["workspace": "T_TEST", "channel": "C_TEST", "user": "U_TEST"],
                                     "sessionID": summary.id, "limit": 2]
        if let cursor { object["cursor"] = cursor }
        return try JSONDecoder().decode(SlackBrowserRequest.self, from: JSONSerialization.data(withJSONObject: object))
    }
    let latest = try await store.slackBrowser(request())
    #expect(latest["source"] as? String == "puckHistory")
    #expect((latest["messages"] as? [[String: Any]])?.compactMap { $0["text"] as? String } == ["before away", "answer"])
    let earlier = try await store.slackBrowser(request(try #require(latest["earlier"] as? String)))
    #expect((earlier["messages"] as? [[String: Any]])?.compactMap { $0["text"] as? String } == ["earliest"])
    #expect(daemon.turns.isEmpty && daemon.creations.isEmpty && !daemon.isFollowed(summary.id))
}

@Test @MainActor
func slackPuckFollowupUsesDaemonAdmissionAndNeverRepeatsAfterDisable() async throws {
    let daemon = FakePuckDaemon()
    let fixture = try PuckStoreFixture(daemon: daemon)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let summary = puckSummary(id: "puck-fixture", cwd: fixture.project.path)
    daemon.put(summary)
    let store = fixture.makeStore()
    defer { store.stopPuckObservation(); store.flushPendingSessionSaves() }
    store.applyPuckSummaries([summary])
    let principal = CodexRemotePrincipal(workspace: "T_TEST", channel: "C_TEST", user: "U_TEST")
    let identity = SlackConversationIdentity(kind: "puck", conversationID: summary.id, generation: "puck")
    try store.codexRemote.configure(.init(enabled: true, allowed: [principal]))
    _ = try store.slackThreadJournal.bind(sessionID: summary.id, identity: identity, principal: principal, slackThread: "100.1")
    let body: [String: Any] = ["action": "followup", "principal": ["workspace": "T_TEST", "channel": "C_TEST", "user": "U_TEST"],
        "sessionID": summary.id, "slackThread": "100.1", "identity": ["kind": "puck", "conversationID": summary.id, "generation": "puck"],
        "operationID": "puck-reply", "text": "Continue\nwith context"]
    let request = try JSONDecoder().decode(SlackBrowserRequest.self, from: JSONSerialization.data(withJSONObject: body))
    let gate = daemon.holdTurns()
    defer { gate.signal() }
    let task = Task { try await store.slackBrowser(request) }
    try await waitForPuckState { daemon.turns.count == 1 }
    try store.codexRemote.configure(.init(enabled: false, allowed: [principal]))
    gate.signal()
    await #expect(throws: (any Error).self) { try await task.value }
    #expect(daemon.turns.count == 1 && daemon.turns[0].prompt == "Continue\nwith context")
    try store.codexRemote.configure(.init(enabled: true, allowed: [principal]))
    let replay = try await store.slackBrowser(request)
    #expect(replay["status"] as? String == "submitted")
    #expect(daemon.turns.count == 1 && daemon.creations.isEmpty)
}

@Test(arguments: ["hibernated", "interrupted"]) @MainActor
func slackPuckFollowupAcceptsKnownInactiveDaemonStates(position: String) async throws {
    let daemon = FakePuckDaemon()
    let fixture = try PuckStoreFixture(daemon: daemon)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let summary = puckSummary(id: "puck-fixture", cwd: fixture.project.path, position: position)
    daemon.put(summary)
    let store = fixture.makeStore()
    defer { store.stopPuckObservation(); store.flushPendingSessionSaves() }
    store.applyPuckSummaries([summary])
    let principal = CodexRemotePrincipal(workspace: "T_TEST", channel: "C_TEST", user: "U_TEST")
    let identity = SlackConversationIdentity(kind: "puck", conversationID: summary.id, generation: "puck")
    try store.codexRemote.configure(.init(enabled: true, allowed: [principal]))
    _ = try store.slackThreadJournal.bind(sessionID: summary.id, identity: identity, principal: principal, slackThread: "100.1")
    let body: [String: Any] = ["action": "followup", "principal": ["workspace": "T_TEST", "channel": "C_TEST", "user": "U_TEST"],
        "sessionID": summary.id, "slackThread": "100.1", "identity": ["kind": "puck", "conversationID": summary.id, "generation": "puck"],
        "operationID": "reply", "text": "Continue"]
    let request = try JSONDecoder().decode(SlackBrowserRequest.self, from: JSONSerialization.data(withJSONObject: body))
    #expect(try await store.slackBrowser(request)["status"] as? String == "submitted")
    #expect(daemon.turns == [.init(id: summary.id, prompt: "Continue")])
}

@Test @MainActor
func slackPuckFollowupRejectsAChangedDaemonBinding() async throws {
    let daemon = FakePuckDaemon()
    let fixture = try PuckStoreFixture(daemon: daemon)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let original = puckSummary(id: "puck-fixture", cwd: fixture.project.path)
    daemon.put(original)
    let store = fixture.makeStore()
    defer { store.stopPuckObservation(); store.flushPendingSessionSaves() }
    store.applyPuckSummaries([original])
    let principal = CodexRemotePrincipal(workspace: "T_TEST", channel: "C_TEST", user: "U_TEST")
    let identity = SlackConversationIdentity(kind: "puck", conversationID: original.id, generation: "puck")
    try store.codexRemote.configure(.init(enabled: true, allowed: [principal]))
    _ = try store.slackThreadJournal.bind(sessionID: original.id, identity: identity, principal: principal, slackThread: "100.1")
    daemon.put(puckSummary(id: original.id, provider: "anthropic", account: "other", model: "other", cwd: fixture.project.path))
    let body: [String: Any] = ["action": "followup", "principal": ["workspace": "T_TEST", "channel": "C_TEST", "user": "U_TEST"],
        "sessionID": original.id, "slackThread": "100.1", "identity": ["kind": "puck", "conversationID": original.id, "generation": "puck"],
        "operationID": "reply", "text": "Continue"]
    let request = try JSONDecoder().decode(SlackBrowserRequest.self, from: JSONSerialization.data(withJSONObject: body))
    await #expect(throws: (any Error).self) { try await store.slackBrowser(request) }
    #expect(daemon.turns.isEmpty)
}

@Test @MainActor
func slackPuckFollowupDoesNotRetryAnUncertainDaemonError() async throws {
    let daemon = FakePuckDaemon()
    let fixture = try PuckStoreFixture(daemon: daemon)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let summary = puckSummary(id: "puck-fixture", cwd: fixture.project.path)
    daemon.put(summary)
    daemon.turnError = .server(.init(code: "fixture", message: "uncertain daemon outcome"))
    let store = fixture.makeStore()
    defer { store.stopPuckObservation(); store.flushPendingSessionSaves() }
    store.applyPuckSummaries([summary])
    let principal = CodexRemotePrincipal(workspace: "T_TEST", channel: "C_TEST", user: "U_TEST")
    let identity = SlackConversationIdentity(kind: "puck", conversationID: summary.id, generation: "puck")
    try store.codexRemote.configure(.init(enabled: true, allowed: [principal]))
    _ = try store.slackThreadJournal.bind(sessionID: summary.id, identity: identity, principal: principal, slackThread: "100.1")
    let body: [String: Any] = ["action": "followup", "principal": ["workspace": "T_TEST", "channel": "C_TEST", "user": "U_TEST"],
        "sessionID": summary.id, "slackThread": "100.1", "identity": ["kind": "puck", "conversationID": summary.id, "generation": "puck"],
        "operationID": "uncertain-reply", "text": "Continue"]
    let request = try JSONDecoder().decode(SlackBrowserRequest.self, from: JSONSerialization.data(withJSONObject: body))
    #expect(try await store.slackBrowser(request)["status"] as? String == "uncertain")
    #expect(try await store.slackBrowser(request)["status"] as? String == "uncertain")
    #expect(daemon.turnAttempts == 1 && daemon.turns.isEmpty)
}

@Test(arguments: ["park", "close"]) @MainActor
func availabilityChangeAfterClaimFencesPuckFollowupBeforeDaemonDispatch(action: String) async throws {
    let daemon = FakePuckDaemon()
    let fixture = try PuckStoreFixture(daemon: daemon)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let summary = puckSummary(id: "puck-fixture", cwd: fixture.project.path)
    daemon.put(summary)
    let store = fixture.makeStore()
    defer { store.stopPuckObservation(); store.flushPendingSessionSaves() }
    store.applyPuckSummaries([summary])
    let principal = CodexRemotePrincipal(workspace: "T_TEST", channel: "C_TEST", user: "U_TEST")
    let identity = SlackConversationIdentity(kind: "puck", conversationID: summary.id, generation: "puck")
    try store.codexRemote.configure(.init(enabled: true, allowed: [principal]))
    let (receipt, _) = try store.slackFollowUpJournal.claim(operationID: "parked-reply", principal: principal,
        sessionID: summary.id, identity: identity, slackThread: "100.1", text: "continue")
    let fence = store.slackFollowUpJournal.fence, key = SlackFollowUpJournal.key(receipt)
    let held = HeldFollowUpDispatch()
    defer { held.release() }
    let task = Task {
        try await store.startPuckTurnImmediately(id: summary.id, prompt: "continue", expiresAt: Date().addingTimeInterval(10),
            willSubmit: { try store.slackFollowUpJournal.markSending(receipt) },
            mayDispatch: { held.wait(); return fence.contains(key) })
    }
    try await waitForPuckState { held.isEntered }
    if action == "park" { try store.suspend(id: summary.id) }
    else { try store.close(id: summary.id) }
    held.release()
    await #expect(throws: (any Error).self) { try await task.value }
    #expect(daemon.turns.isEmpty)
    try store.slackFollowUpJournal.rejectBeforeSend(receipt, reason: "session_changed")
    #expect(try store.slackFollowUpJournal.receipt(operationID: "parked-reply", principal: principal)?.status == "rejected")
}

@Test @MainActor
func slackPuckApprovalUsesExactCurrentCallAndDoesNotReplay() async throws {
    let daemon = FakePuckDaemon()
    let fixture = try PuckStoreFixture(daemon: daemon)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let pending = PuckPendingApproval(callID: "approval-a", tool: "shell", arguments: "run fixture command", expiresAtMS: .max)
    let summary = puckSummary(id: "puck-fixture", cwd: fixture.project.path, position: "parked", pendingApproval: pending)
    daemon.put(summary, transcript: [.init(cursor: 1, kind: "text_delta", text: "prior context")])
    let store = fixture.makeStore()
    defer { store.stopPuckObservation(); store.flushPendingSessionSaves() }
    store.applyPuckSummaries([summary])
    let principal = CodexRemotePrincipal(workspace: "T_TEST", channel: "C_TEST", user: "U_TEST")
    let identity = SlackConversationIdentity(kind: "puck", conversationID: summary.id, generation: "puck")
    try store.codexRemote.configure(.init(enabled: true, allowed: [principal]))
    _ = try store.slackThreadJournal.bind(sessionID: summary.id, identity: identity, principal: principal, slackThread: "100.1")
    func request(_ action: String, requestID: String? = nil, operationID: String? = nil, option: Int? = nil) throws -> SlackBrowserRequest {
        var body: [String: Any] = ["action": action, "principal": ["workspace": "T_TEST", "channel": "C_TEST", "user": "U_TEST"],
            "sessionID": summary.id, "slackThread": "100.1", "identity": ["kind": "puck", "conversationID": summary.id, "generation": "puck"]]
        if let requestID { body["requestID"] = requestID }
        if let operationID { body["operationID"] = operationID }
        if let option { body["option"] = option }
        return try JSONDecoder().decode(SlackBrowserRequest.self, from: JSONSerialization.data(withJSONObject: body))
    }
    let card = try await store.slackBrowser(request("decision"))
    #expect(card["question"] as? String == "Approval needed: shell")
    #expect((card["context"] as? [String]) == ["run fixture command"])
    #expect((card["options"] as? [[String: Any]])?.compactMap { $0["label"] as? String } == ["Approve", "Approve for Session", "Deny"])
    #expect(((card["recentContext"] as? [[String: Any]])?.first)?["text"] as? String == "prior context")
    let requestID = try #require(card["requestID"] as? String)
    let answer = try request("answer", requestID: requestID, operationID: "approval-reply", option: 3)
    #expect(try await store.slackBrowser(answer)["status"] as? String == "submitted")
    #expect(try await store.slackBrowser(answer)["status"] as? String == "submitted")
    #expect(daemon.decisions == ["deny"])
    #expect(try await store.slackBrowser(request("decision"))["status"] as? String == "resolved")

    let next = PuckPendingApproval(callID: "approval-b", tool: "shell", arguments: "another command", expiresAtMS: .max)
    daemon.put(summary.with(pendingApproval: .some(next)))
    let newCard = try await store.slackBrowser(request("decision"))
    let newID = try #require(newCard["requestID"] as? String)
    daemon.put(summary.with(position: "running", pendingApproval: .some(nil)))
    await #expect(throws: (any Error).self) {
        try await store.slackBrowser(request("answer", requestID: newID, operationID: "stale-reply", option: 1))
    }
    #expect(daemon.decisions == ["deny"])
}

@Test @MainActor
func slackAwayObservesANewPuckRequestWithoutAStatusTransition() async throws {
    let daemon = FakePuckDaemon()
    let fixture = try PuckStoreFixture(daemon: daemon)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let approval = PuckPendingApproval(callID: "first", tool: "shell", arguments: "first command", expiresAtMS: .max)
    let summary = puckSummary(id: "puck-fixture", cwd: fixture.project.path, position: "parked", pendingApproval: approval)
    daemon.put(summary)
    let store = fixture.makeStore()
    defer { store.stopPuckObservation(); store.flushPendingSessionSaves() }
    store.applyPuckSummaries([summary])
    let principal = CodexRemotePrincipal(workspace: "T_TEST", channel: "C_TEST", user: "U_TEST")
    try store.codexRemote.configure(.init(enabled: true, allowed: [principal]))
    _ = try store.slackAwayJournal.configure(principal: principal, enabled: nil, sessionID: summary.id,
        projectID: nil, follow: true, epoch: store.slackSessionEventEpoch, cursor: store.sessionEvents(since: nil).cursor)
    _ = try store.slackAwayJournal.configure(principal: principal, enabled: true, sessionID: nil,
        projectID: nil, follow: nil, epoch: store.slackSessionEventEpoch, cursor: store.sessionEvents(since: nil).cursor)
    let cursor = store.sessionEvents(since: nil).cursor
    let changed = PuckPendingApproval(callID: "second", tool: "shell", arguments: "second command", expiresAtMS: .max)
    let next = summary.with(pendingApproval: .some(changed))
    store.applyPuckSummaries([next])
    store.applyPuckSummaries([next])
    let events = store.sessionEvents(since: cursor).events
    #expect(events.count == 1 && events.first?.sessionID == summary.id)
    _ = try store.slackAwayJournal.configure(principal: principal, enabled: false, sessionID: nil,
        projectID: nil, follow: nil, epoch: store.slackSessionEventEpoch, cursor: store.sessionEvents(since: nil).cursor)
    daemon.put(next)
    let identity = SlackConversationIdentity(kind: "puck", conversationID: summary.id, generation: "puck")
    _ = try store.slackThreadJournal.bind(sessionID: summary.id, identity: identity, principal: principal, slackThread: "100.1")
    let body: [String: Any] = ["action": "decision", "principal": ["workspace": "T_TEST", "channel": "C_TEST", "user": "U_TEST"],
        "sessionID": summary.id, "slackThread": "100.1", "identity": ["kind": "puck", "conversationID": summary.id, "generation": "puck"]]
    let request = try JSONDecoder().decode(SlackBrowserRequest.self, from: JSONSerialization.data(withJSONObject: body))
    _ = try await store.slackBrowser(request)
    let offCursor = store.sessionEvents(since: nil).cursor
    let third = PuckPendingApproval(callID: "third", tool: "shell", arguments: "third command", expiresAtMS: .max)
    store.applyPuckSummaries([summary.with(pendingApproval: .some(third))])
    #expect(store.sessionEvents(since: offCursor).events.count == 1)
}

@Test @MainActor
func slackPuckQuestionPreservesMultipleAndCustomSelectionsAndReceipt() async throws {
    let daemon = FakePuckDaemon()
    let fixture = try PuckStoreFixture(daemon: daemon)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let pending = try PuckPendingQuestion(["call_id": "question-a", "expires_at_ms": NSNumber(value: UInt64.max),
        "questions": [
            ["header": "First", "question": "Which checks?", "multiple": true, "custom": false,
             "options": [["label": "A", "description": "First check"], ["label": "B", "description": "Second check"]]],
            ["header": "Second", "question": "Any details?", "multiple": false, "custom": true,
             "options": [["label": "None", "description": "No details"]]]
        ]])
    let summary = puckSummary(id: "puck-fixture", cwd: fixture.project.path, position: "parked", pendingQuestion: pending)
    daemon.put(summary)
    let store = fixture.makeStore()
    defer { store.stopPuckObservation(); store.flushPendingSessionSaves() }
    store.applyPuckSummaries([summary])
    let principal = CodexRemotePrincipal(workspace: "T_TEST", channel: "C_TEST", user: "U_TEST")
    let identity = SlackConversationIdentity(kind: "puck", conversationID: summary.id, generation: "puck")
    try store.codexRemote.configure(.init(enabled: true, allowed: [principal]))
    _ = try store.slackThreadJournal.bind(sessionID: summary.id, identity: identity, principal: principal, slackThread: "100.1")
    var body: [String: Any] = ["action": "decision", "principal": ["workspace": "T_TEST", "channel": "C_TEST", "user": "U_TEST"],
        "sessionID": summary.id, "slackThread": "100.1", "identity": ["kind": "puck", "conversationID": summary.id, "generation": "puck"]]
    func request() throws -> SlackBrowserRequest {
        try JSONDecoder().decode(SlackBrowserRequest.self, from: JSONSerialization.data(withJSONObject: body))
    }
    let card = try await store.slackBrowser(request())
    #expect(card["kind"] as? String == "puckQuestion" && card["answerable"] as? Bool == true)
    #expect((card["questions"] as? [[String: Any]])?.count == 2)
    body["action"] = "answer"; body["requestID"] = try #require(card["requestID"] as? String)
    body["operationID"] = "invalid-reply"; body["option"] = 1
    body["selections"] = [["labels": ["not offered"]], ["labels": ["None"]]]
    #expect(try await store.slackBrowser(request())["status"] as? String == "rejected")
    #expect(daemon.answers.isEmpty)
    body["action"] = "decision"
    let refreshed = try await store.slackBrowser(request())
    body["action"] = "answer"; body["requestID"] = try #require(refreshed["requestID"] as? String)
    body["operationID"] = "question-reply"
    body["selections"] = [["labels": ["B", "A"]], ["labels": [], "text": "  custom details  "]]
    let answer = try request()
    #expect(try await store.slackBrowser(answer)["status"] as? String == "submitted")
    #expect(try await store.slackBrowser(answer)["status"] as? String == "submitted")
    #expect(daemon.answers == [[.init(labels: ["A", "B"]), .init(text: "custom details")]])
    body["selections"] = [["labels": ["A"]], ["labels": [], "text": "different"]]
    await #expect(throws: (any Error).self) { try await store.slackBrowser(request()) }
    #expect(daemon.answers.count == 1)
}

@Test @MainActor
func fakeSlackAwayCatchupAnswersAnExistingPuckApprovalThroughHTTP() async throws {
    let daemon = FakePuckDaemon()
    let fixture = try PuckStoreFixture(daemon: daemon)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let pending = PuckPendingApproval(callID: "approval-a", tool: "shell", arguments: "run fixture command", expiresAtMS: .max)
    let summary = puckSummary(id: "puck-fixture", cwd: fixture.project.path, position: "parked", pendingApproval: pending)
    daemon.put(summary, transcript: [.init(cursor: 1, kind: "text_delta", text: "prior context")])
    let store = fixture.makeStore()
    defer { store.stopPuckObservation(); store.flushPendingSessionSaves() }
    store.applyPuckSummaries([summary])
    let principal = CodexRemotePrincipal(workspace: "T_TEST", channel: "C_TEST", user: "U_TEST")
    try store.codexRemote.configure(.init(enabled: true, allowed: [principal]))
    let server = ControlServer(store: store, host: store.host, port: .any)
    server.start(); defer { server.stop() }
    try await waitForPuckState { server.listeningPort != nil }
    let config: [String: Any] = ["controlURL": "http://127.0.0.1:\(try #require(server.listeningPort))",
        "tokenFile": ControlToken.tokenFileURL(environment: store.host.environment, homeDirectory: store.host.homeDirectory).path,
        "state": fixture.root.appendingPathComponent("connector.json").path, "mode": "puck_away"]
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
    #expect(status == 0, "Fake Slack Puck driver failed: \(String(decoding: data, as: UTF8.self))")
    #expect(daemon.decisions == ["deny"])
}

@Test @MainActor
func puckDecisionRechecksDesktopResolutionAndDisableBeforeDispatch() async throws {
    let daemon = FakePuckDaemon()
    let fixture = try PuckStoreFixture(daemon: daemon)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let first = PuckPendingApproval(callID: "approval-a", tool: "shell", arguments: "first", expiresAtMS: .max)
    let summary = puckSummary(id: "puck-fixture", cwd: fixture.project.path, position: "parked", pendingApproval: first)
    daemon.put(summary)
    let store = fixture.makeStore()
    defer { store.stopPuckObservation(); store.flushPendingSessionSaves() }
    store.applyPuckSummaries([summary])
    let principal = CodexRemotePrincipal(workspace: "T_TEST", channel: "C_TEST", user: "U_TEST")
    let identity = SlackConversationIdentity(kind: "puck", conversationID: summary.id, generation: "puck")
    try store.codexRemote.configure(.init(enabled: true, allowed: [principal]))
    _ = try store.slackThreadJournal.bind(sessionID: summary.id, identity: identity, principal: principal, slackThread: "100.1")
    func request(_ action: String, requestID: String? = nil, operation: String? = nil) throws -> SlackBrowserRequest {
        var body: [String: Any] = ["action": action, "principal": ["workspace": "T_TEST", "channel": "C_TEST", "user": "U_TEST"],
            "sessionID": summary.id, "slackThread": "100.1", "identity": ["kind": "puck", "conversationID": summary.id, "generation": "puck"]]
        if let requestID { body["requestID"] = requestID }
        if let operation { body["operationID"] = operation; body["option"] = 1 }
        return try JSONDecoder().decode(SlackBrowserRequest.self, from: JSONSerialization.data(withJSONObject: body))
    }
    let firstCard = try await store.slackBrowser(request("decision"))
    let firstID = try #require(firstCard["requestID"] as? String)
    let before = daemon.getsStarted
    let gate = daemon.holdNextGet(after: 3)
    defer { gate.signal() }
    let firstTask = Task { try await store.slackBrowser(request("answer", requestID: firstID, operation: "desktop-race")) }
    try await waitForPuckState { daemon.getsStarted >= before + 4 }
    daemon.put(summary.with(position: "running", pendingApproval: .some(nil)))
    gate.signal()
    #expect(try await firstTask.value["status"] as? String == "rejected")
    #expect(daemon.decisions.isEmpty)

    let second = PuckPendingApproval(callID: "approval-b", tool: "shell", arguments: "second", expiresAtMS: .max)
    daemon.put(summary.with(pendingApproval: .some(second)))
    let secondCard = try await store.slackBrowser(request("decision"))
    let secondID = try #require(secondCard["requestID"] as? String)
    let beforeDisable = daemon.getsStarted
    let disableGate = daemon.holdNextGet(after: 3)
    defer { disableGate.signal() }
    let secondTask = Task { try await store.slackBrowser(request("answer", requestID: secondID, operation: "disable-race")) }
    try await waitForPuckState { daemon.getsStarted >= beforeDisable + 4 }
    try store.codexRemote.configure(.init(enabled: false, allowed: [principal]))
    disableGate.signal()
    await #expect(throws: (any Error).self) { try await secondTask.value }
    #expect(daemon.decisions.isEmpty)

    try store.codexRemote.configure(.init(enabled: true, allowed: [principal]))
    let third = PuckPendingApproval(callID: "approval-c", tool: "shell", arguments: "third", expiresAtMS: .max)
    let thirdSummary = summary.with(pendingApproval: .some(third))
    daemon.put(thirdSummary); store.applyPuckSummaries([thirdSummary])
    let thirdCard = try await store.slackBrowser(request("decision"))
    let thirdID = try #require(thirdCard["requestID"] as? String)
    let beforeSuspend = daemon.getsStarted
    let suspendGate = daemon.holdNextGet(after: 3)
    defer { suspendGate.signal() }
    let thirdTask = Task { try await store.slackBrowser(request("answer", requestID: thirdID, operation: "suspend-race")) }
    try await waitForPuckState { daemon.getsStarted >= beforeSuspend + 4 }
    try store.suspend(id: summary.id)
    suspendGate.signal()
    #expect(try await thirdTask.value["status"] as? String == "rejected")
    #expect(daemon.decisions.isEmpty)
}

@Test @MainActor
func fakeSlackPuckQuestionFormReachesTheExactDaemonRequestThroughHTTP() async throws {
    let daemon = FakePuckDaemon()
    let fixture = try PuckStoreFixture(daemon: daemon)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let pending = try PuckPendingQuestion(["call_id": "question-a", "expires_at_ms": NSNumber(value: UInt64.max),
        "questions": [
            ["header": "First", "question": "Which checks?", "multiple": true, "custom": false,
             "options": [["label": "A", "description": "First"], ["label": "B", "description": "Second"]]],
            ["header": "Second", "question": "Any details?", "multiple": false, "custom": true,
             "options": [["label": "None", "description": "No details"]]]
        ]])
    let summary = puckSummary(id: "puck-fixture", cwd: fixture.project.path, position: "parked", pendingQuestion: pending)
    daemon.put(summary)
    let store = fixture.makeStore()
    defer { store.stopPuckObservation(); store.flushPendingSessionSaves() }
    store.applyPuckSummaries([summary])
    let principal = CodexRemotePrincipal(workspace: "T_TEST", channel: "C_TEST", user: "U_TEST")
    try store.codexRemote.configure(.init(enabled: true, allowed: [principal]))
    let server = ControlServer(store: store, host: store.host, port: .any)
    server.start(); defer { server.stop() }
    try await waitForPuckState { server.listeningPort != nil }
    let config: [String: Any] = ["controlURL": "http://127.0.0.1:\(try #require(server.listeningPort))",
        "tokenFile": ControlToken.tokenFileURL(environment: store.host.environment, homeDirectory: store.host.homeDirectory).path,
        "state": fixture.root.appendingPathComponent("connector.json").path, "mode": "puck_question"]
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
    #expect(status == 0, "Fake Slack Puck form failed: \(String(decoding: data, as: UTF8.self))")
    #expect(daemon.answers == [[.init(labels: ["A", "B"]), .init(text: "details")]])
}
