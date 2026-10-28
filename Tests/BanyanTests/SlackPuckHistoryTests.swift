import Foundation
import Testing
@testable import Banyan
@testable import BanyanCore

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
