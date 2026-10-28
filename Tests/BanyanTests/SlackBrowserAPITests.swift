import Foundation
import Testing
@testable import Banyan
@testable import BanyanCore

private actor HeldSlackContext: TerminalConversationContextReading {
    private var entered = false
    private var started: CheckedContinuation<Void, Never>?
    private var held: CheckedContinuation<Void, Never>?
    private(set) var calls = 0

    func waitUntilStarted() async {
        if entered { return }
        await withCheckedContinuation { started = $0 }
    }
    func release() { held?.resume(); held = nil }
    func read(sessionID: String, sessionName: String, provider: CodingAgentProvider?,
              earlier: String?, limit: Int, terminalOutput: Bool) async throws -> TerminalConversationContextReader.Context {
        calls += 1
        entered = true
        started?.resume(); started = nil
        await withCheckedContinuation { held = $0 }
        return .init(source: .providerTranscript, conversationID: "fixture-thread", binding: nil,
            messages: [.init(role: "user", text: "private fixture", truncated: false)],
            earlier: nil, output: nil, limitation: nil, truncated: false, mayBeStale: false)
    }
}

private final class BrowserPane: TmuxSessionBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var text = "retained terminal output"
    func setText(_ value: String) { lock.lock(); defer { lock.unlock() }; text = value }
    func hasSession(named: String) -> Bool { true }
    func primaryPaneSnapshot(named: String) -> TmuxPaneSnapshot? {
        .init(paneID: "%1", rootPID: 100, currentCommand: "codex", currentPath: "/tmp", isDead: false, isInMode: false)
    }
    func captureVisibleText(paneID: String, lineLimit: Int) -> String { lock.lock(); defer { lock.unlock() }; return text }
}

private struct BrowserInspector: CodexTUIProcessInspecting {
    let path: String
    func tree(rootPID: Int32) throws -> [CodexTUIProcess] {
        [.init(identity: .init(pid: 100, startSeconds: 1, startMicroseconds: 0), isCodex: false, openRollouts: []),
         .init(identity: .init(pid: 101, startSeconds: 2, startMicroseconds: 0), isCodex: true, openRollouts: [path])]
    }
    func hasExited(_ identity: AgentProcessIdentity) throws -> Bool { false }
}

@MainActor
@Suite(.serialized)
struct SlackBrowserAPITests {
    private let principal = CodexRemotePrincipal(workspace: "T_TEST", channel: "C_TEST", user: "U_TEST")

    private func fixture() throws -> (PuckStoreFixture, SessionStore, ControlServer) {
        let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
        let now = Date()
        fixture.persistence.save((0..<25).map { index in
            SessionSnapshot(id: "row-\(index)", tmuxSessionName: "banyan-row-\(index)",
                title: "Fixture \(index)", reportedTitle: nil, isTitlePinned: true,
                cwd: fixture.project.path, command: "codex", status: .closed, tone: .blue,
                createdAt: now, updatedAt: now.addingTimeInterval(Double(index)))
        })
        let store = fixture.makeStore()
        store.loadPersistedSessionsIfNeeded()
        for (index, session) in store.sessions.enumerated() {
            session.status = index == 0 ? .asking : .executing
            session.projectGroupTitle = index < 13 ? "Alpha" : "Beta"
            session.projectGroupID = index < 13 ? "alpha" : "beta"
        }
        let server = ControlServer(store: store, host: store.host, port: .any)
        server.start()
        return (fixture, store, server)
    }

    private func post(_ path: String = "/slack-browser", body: [String: Any], store: SessionStore,
                      server: ControlServer, includeToken: Bool = true) async throws -> (Int, [String: Any]) {
        let port = try #require(server.listeningPort)
        var request = URLRequest(url: try #require(URL(string: "http://127.0.0.1:\(port)\(path)")))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if includeToken {
            let token = try ControlToken.loadOrCreate(environment: store.host.environment, homeDirectory: store.host.homeDirectory)
            request.setValue(token, forHTTPHeaderField: ControlToken.headerName)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        return (try #require((response as? HTTPURLResponse)?.statusCode),
                try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]))
    }

    private var principalBody: [String: String] { ["workspace": principal.workspace, "channel": principal.channel, "user": principal.user] }

    @Test func replacingTheControlChannelStartsWithAnEmptyAwayScope() async throws {
        let (_, store, server) = try fixture()
        defer { server.stop(); store.stopPuckObservation(); store.flushPendingSessionSaves() }
        try await waitForPuckState { server.listeningPort != nil }
        try store.codexRemote.configure(.init(enabled: true, allowed: [principal]))
        #expect(try await post(body: ["action": "awayConfigure", "principal": principalBody,
            "followSessionID": "row-0", "follow": true], store: store, server: server).0 == 200)
        #expect(try await post(body: ["action": "awayConfigure", "principal": principalBody,
            "awayEnabled": true], store: store, server: server).0 == 200)
        try store.codexRemote.configure(.init(enabled: false, allowed: [principal]))
        let retained = try store.slackAwayJournal.status(principal: principal)
        #expect(retained.enabled && retained.sessionIDs == ["row-0"])
        let replacement = CodexRemotePrincipal(workspace: "T_TEST", channel: "C_OTHER", user: "U_TEST")
        try store.codexRemote.configure(.init(enabled: true, allowed: [replacement]))
        let other = ["workspace": "T_TEST", "channel": "C_OTHER", "user": "U_TEST"]
        let (status, response) = try await post(body: ["action": "awayStatus", "principal": other], store: store, server: server)
        let away = try #require(response["data"] as? [String: Any])
        #expect(status == 200 && (away["enabled"] as? Bool) == false)
        #expect((away["sessionIDs"] as? [String])?.isEmpty == true)
        #expect(try await post(body: ["action": "awayStatus", "principal": principalBody], store: store, server: server).0 == 403)
    }

    @Test func browserRequiresBothLocalTokenAndExactTupleAndPaginatesMetadata() async throws {
        let (_, store, server) = try fixture()
        defer { server.stop(); store.stopPuckObservation(); store.flushPendingSessionSaves() }
        let gate = HeldSlackContext()
        store.slackTerminalContext = gate
        try await waitForPuckState { server.listeningPort != nil }
        let body: [String: Any] = ["action": "list", "principal": principalBody, "limit": 10]
        #expect(try await post(body: body, store: store, server: server, includeToken: false).0 == 401)
        #expect(try await post(body: body, store: store, server: server).0 == 403)
        try store.codexRemote.configure(.init(enabled: true, allowed: []))
        #expect(try await post(body: body, store: store, server: server).0 == 403)
        try store.codexRemote.configure(.init(enabled: true, allowed: [principal]))
        let (status, first) = try await post(body: body, store: store, server: server)
        #expect(status == 200)
        let firstData = try #require(first["data"] as? [String: Any])
        let firstRows = try #require(firstData["sessions"] as? [[String: Any]])
        #expect(firstRows.count == 10)
        #expect(firstData["total"] as? Int == 25)
        let next = try #require(firstData["nextOffset"] as? Int)
        let (_, second) = try await post(body: ["action": "list", "principal": principalBody, "limit": 10, "offset": next], store: store, server: server)
        let secondRows = try #require((second["data"] as? [String: Any])?["sessions"] as? [[String: Any]])
        #expect(Set(firstRows.compactMap { $0["sessionID"] as? String }).isDisjoint(with: Set(secondRows.compactMap { $0["sessionID"] as? String })))
        #expect(firstRows.map { $0["project"] as? String }.allSatisfy { $0 == "Alpha" })
        let (_, searched) = try await post(body: ["action": "list", "principal": principalBody, "query": "beta"], store: store, server: server)
        let found = try #require((searched["data"] as? [String: Any])?["sessions"] as? [[String: Any]])
        #expect(found.allSatisfy { $0["project"] as? String == "Beta" })
        #expect(!found.isEmpty)
        let (_, needs) = try await post(body: ["action": "list", "principal": principalBody, "filter": "needs"], store: store, server: server)
        #expect(((needs["data"] as? [String: Any])?["total"] as? Int) == 1)
        #expect(await gate.calls == 0)
        let wrong: [String: Any] = ["action": "list", "principal": ["workspace": "T_TEST", "channel": "C_TEST", "user": "U_OTHER"]]
        #expect(try await post(body: wrong, store: store, server: server).0 == 403)
        try store.codexRemote.configure(.init(enabled: false, allowed: [principal]))
        #expect(try await post(body: body, store: store, server: server).0 == 403)
    }

    @Test func browserReadsExistingHistoryAndBindsPagesToTheSelectedRow() async throws {
        let (fixture, store, server) = try fixture()
        defer { server.stop(); store.stopPuckObservation(); store.flushPendingSessionSaves() }
        let url = fixture.root.appendingPathComponent("rollout-test.jsonl")
        let transcript = [
            #"{"type":"session_meta","payload":{"id":"thread"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"before away"}]}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"answer"}]}}"#
        ].joined(separator: "\n") + "\n"
        try Data(transcript.utf8).write(to: url)
        store.slackTerminalContext = TerminalConversationContextReader(backend: BrowserPane(), inspector: BrowserInspector(path: url.path))
        try store.codexRemote.configure(.init(enabled: true, allowed: [principal]))
        try await waitForPuckState { server.listeningPort != nil }
        let session = try #require(store.sessions.first)
        let another = try #require(store.sessions.dropFirst().first)
        let (status, first) = try await post(body: ["action": "context", "principal": principalBody,
            "sessionID": session.id, "limit": 1], store: store, server: server)
        #expect(status == 200)
        let data = try #require(first["data"] as? [String: Any])
        #expect(data["source"] as? String == "providerTranscript")
        let latest = try #require(data["messages"] as? [[String: Any]])
        #expect(latest.first?["text"] as? String == "answer")
        let cursor = try #require(data["earlier"] as? String)
        let (_, older) = try await post(body: ["action": "context", "principal": principalBody,
            "sessionID": session.id, "cursor": cursor], store: store, server: server)
        let olderRows = try #require((older["data"] as? [String: Any])?["messages"] as? [[String: Any]])
        #expect(olderRows.first?["text"] as? String == "before away")
        let (wrongStatus, wrong) = try await post(body: ["action": "context", "principal": principalBody,
            "sessionID": another.id, "cursor": cursor], store: store, server: server)
        #expect(wrongStatus == 409)
        #expect(wrong["data"] == nil)
    }

    @Test func sessionThreadReusesItsBindingAndRejectsChangedConversation() async throws {
        let (fixture, store, server) = try fixture()
        defer { server.stop(); store.stopPuckObservation(); store.flushPendingSessionSaves() }
        let url = fixture.root.appendingPathComponent("rollout-test.jsonl")
        let transcript = #"{"type":"session_meta","payload":{"id":"thread"}}"# + "\n" +
            #"{"type":"event_msg","payload":{"type":"user_message","message":"before away"}}"# + "\n"
        try Data(transcript.utf8).write(to: url)
        let generationFile = fixture.root.appendingPathComponent("generation-index.json")
        store.slackTerminalContext = TerminalConversationContextReader(backend: BrowserPane(), inspector: BrowserInspector(path: url.path),
            generations: SlackConversationGenerationTracker(file: generationFile))
        try store.codexRemote.configure(.init(enabled: true, allowed: [principal]))
        try await waitForPuckState { server.listeningPort != nil }
        let session = try #require(store.sessions.first)
        let other = try #require(store.sessions.dropFirst().first)
        func open(_ id: String) async throws -> [String: Any] {
            let (status, response) = try await post(body: ["action": "open", "principal": principalBody, "sessionID": id], store: store, server: server)
            #expect(status == 200)
            return try #require(response["data"] as? [String: Any])
        }
        let first = try await open(session.id)
        let identity = try #require(first["binding"] as? [String: Any])
        #expect(first["attachment"] is NSNull)
        let (bindStatus, bound) = try await post(body: ["action": "bind", "principal": principalBody,
            "sessionID": session.id, "identity": identity, "slackThread": "100.123"], store: store, server: server)
        #expect(bindStatus == 200)
        let attachment = try #require((bound["data"] as? [String: Any])?["attachment"] as? [String: Any])
        let reused = try await open(session.id)
        #expect((reused["attachment"] as? [String: Any])?["id"] as? String == attachment["id"] as? String)
        #expect((reused["attachment"] as? [String: Any])?["slackThread"] as? String == "100.123")
        let boundRead: [String: Any] = ["action": "boundContext", "principal": principalBody,
            "sessionID": session.id, "identity": identity, "slackThread": "100.123"]
        let (readStatus, readResult) = try await post(body: boundRead, store: store, server: server)
        #expect(readStatus == 200)
        #expect(((readResult["data"] as? [String: Any])?["messages"] as? [[String: Any]])?.first?["text"] as? String == "before away")
        var wrongRoot = boundRead; wrongRoot["slackThread"] = "999.123"
        #expect(try await post(body: wrongRoot, store: store, server: server).0 == 409)
        var outputRead = boundRead; outputRead["terminalOutput"] = true
        let (outputStatus, output) = try await post(body: outputRead, store: store, server: server)
        #expect(outputStatus == 200)
        #expect((output["data"] as? [String: Any])?["output"] as? String == "retained terminal output")
        let appended = try FileHandle(forWritingTo: url)
        try appended.seekToEnd()
        try appended.write(contentsOf: Data((#"{"type":"event_msg","payload":{"type":"agent_message","message":"progress"}}"# + "\n").utf8))
        try appended.close()
        let afterAppend = try await open(session.id)
        #expect((afterAppend["attachment"] as? [String: Any])?["slackThread"] as? String == "100.123")
        store.slackTerminalContext = TerminalConversationContextReader(backend: BrowserPane(), inspector: BrowserInspector(path: url.path),
            generations: SlackConversationGenerationTracker(file: generationFile))
        let afterRestart = try await open(session.id)
        #expect((afterRestart["attachment"] as? [String: Any])?["slackThread"] as? String == "100.123")
        let otherOpen = try await open(other.id)
        let otherIdentity = try #require(otherOpen["binding"] as? [String: Any])
        let (collision, _) = try await post(body: ["action": "bind", "principal": principalBody,
            "sessionID": other.id, "identity": otherIdentity, "slackThread": "100.123"], store: store, server: server)
        #expect(collision == 409)
        let file = try FileHandle(forWritingTo: url)
        try file.seekToEnd()
        try file.write(contentsOf: Data((#"{"type":"event_msg","payload":{"type":"user_message","message":"/clear"}}"# + "\n").utf8))
        try file.close()
        let changed = try await open(session.id)
        let newIdentity = try #require(changed["binding"] as? [String: Any])
        #expect(newIdentity["generation"] as? String != identity["generation"] as? String)
        #expect(changed["attachment"] is NSNull)
        #expect(try await post(body: boundRead, store: store, server: server).0 == 409)
        let (stale, _) = try await post(body: ["action": "bind", "principal": principalBody,
            "sessionID": session.id, "identity": identity, "slackThread": "200.123"], store: store, server: server)
        #expect(stale == 409)
        let (newStatus, _) = try await post(body: ["action": "bind", "principal": principalBody,
            "sessionID": session.id, "identity": newIdentity, "slackThread": "200.123"], store: store, server: server)
        #expect(newStatus == 200)
        // An in-place compaction that removes the reset must not resurrect the
        // earlier generation and its old Slack thread.
        try Data(transcript.utf8).write(to: url)
        let compacted = try await open(session.id)
        let compactedIdentity = try #require(compacted["binding"] as? [String: Any])
        #expect(compactedIdentity["generation"] as? String != identity["generation"] as? String)
        #expect(compacted["attachment"] is NSNull)
    }

    @Test func observedResetRetiresTheReadOnlyPaneBinding() async throws {
        let (_, store, server) = try fixture()
        defer { server.stop(); store.stopPuckObservation(); store.flushPendingSessionSaves() }
        let pane = BrowserPane()
        store.slackTerminalContext = TerminalConversationContextReader(backend: pane,
            inspector: BrowserInspector(path: "/tmp/missing-transcript.jsonl"))
        try store.codexRemote.configure(.init(enabled: true, allowed: [principal]))
        try await waitForPuckState { server.listeningPort != nil }
        let session = try #require(store.sessions.first)
        let (_, first) = try await post(body: ["action": "open", "principal": principalBody, "sessionID": session.id], store: store, server: server)
        let identity = try #require((first["data"] as? [String: Any])?["binding"] as? [String: Any])
        #expect(identity["kind"] as? String == "terminalPane")
        let (bound, _) = try await post(body: ["action": "bind", "principal": principalBody,
            "sessionID": session.id, "identity": identity, "slackThread": "100.123"], store: store, server: server)
        #expect(bound == 200)
        pane.setText("new conversation output")
        let (changedStatus, _) = try await post(body: ["action": "boundContext", "principal": principalBody,
            "sessionID": session.id, "identity": identity, "slackThread": "100.123"], store: store, server: server)
        #expect(changedStatus == 409)
        let (_, changed) = try await post(body: ["action": "open", "principal": principalBody, "sessionID": session.id], store: store, server: server)
        let changedIdentity = try #require((changed["data"] as? [String: Any])?["binding"] as? [String: Any])
        #expect((changedIdentity["generation"] as? String) != (identity["generation"] as? String))
        session.lastConversationResetAt = Date()
        let (oldStatus, _) = try await post(body: ["action": "boundContext", "principal": principalBody,
            "sessionID": session.id, "identity": identity, "slackThread": "100.123"], store: store, server: server)
        #expect(oldStatus == 409)
        let (_, reopened) = try await post(body: ["action": "open", "principal": principalBody, "sessionID": session.id], store: store, server: server)
        let current = try #require((reopened["data"] as? [String: Any])?["binding"] as? [String: Any])
        #expect((current["generation"] as? String) != (changedIdentity["generation"] as? String))
        #expect((reopened["data"] as? [String: Any])?["attachment"] is NSNull)
    }

    @Test func awayEventsWakeOnTransitionsAndDisable() async throws {
        let (_, store, server) = try fixture()
        defer { server.stop(); store.stopPuckObservation(); store.flushPendingSessionSaves() }
        try store.codexRemote.configure(.init(enabled: true, allowed: [principal]))
        try await waitForPuckState { server.listeningPort != nil }
        let id = try #require(store.sessions.first?.id)
        _ = try await post(body: ["action": "awayConfigure", "principal": principalBody,
            "followSessionID": id, "follow": true], store: store, server: server)
        let (_, enabledResponse) = try await post(body: ["action": "awayConfigure", "principal": principalBody,
            "awayEnabled": true], store: store, server: server)
        let enabled = try #require(enabledResponse["data"] as? [String: Any])
        let initialRequest: [String: Any] = ["action": "awayEvents", "principal": principalBody,
            "eventEpoch": try #require(enabled["checkpointEpoch"] as? String),
            "eventCursor": try #require(enabled["checkpointCursor"] as? Int),
            "awayActivationID": try #require(enabled["activationID"] as? String),
            "awayRevision": try #require(enabled["revision"] as? Int)]
        let waiting = Task { try await post(body: initialRequest, store: store, server: server) }
        try await waitForPuckState { server.parkedAwayWaiterCount == 1 }
        try #require(store.sessions.first).mark(status: .completed)
        let (status, response) = try await waiting.value
        #expect(status == 200)
        let batch = try #require(response["data"] as? [String: Any])
        let events = try #require(batch["events"] as? [[String: Any]])
        #expect(events.contains { $0["sessionID"] as? String == id && $0["status"] as? String == "completed" })
        var nextRequest = initialRequest
        nextRequest["eventCursor"] = try #require(batch["cursor"] as? Int)
        let waitingRequest = nextRequest
        let waitingForDisable = Task { try await post(body: waitingRequest, store: store, server: server) }
        try await waitForPuckState { server.parkedAwayWaiterCount == 1 }
        _ = try await post(body: ["action": "awayConfigure", "principal": principalBody, "awayEnabled": false], store: store, server: server)
        let (_, offResponse) = try await waitingForDisable.value
        let off = try #require(offResponse["data"] as? [String: Any])
        #expect(off["enabled"] as? Bool == false)
        #expect((off["events"] as? [[String: Any]])?.isEmpty == true)
    }

    @Test func awayEventsReportEpochAndExpiredCursorGaps() async throws {
        let (_, store, server) = try fixture()
        defer { server.stop(); store.stopPuckObservation(); store.flushPendingSessionSaves() }
        try store.codexRemote.configure(.init(enabled: true, allowed: [principal]))
        try await waitForPuckState { server.listeningPort != nil }
        let session = try #require(store.sessions.first)
        _ = try await post(body: ["action": "awayConfigure", "principal": principalBody,
            "followSessionID": session.id, "follow": true], store: store, server: server)
        let (_, enabledResponse) = try await post(body: ["action": "awayConfigure", "principal": principalBody,
            "awayEnabled": true], store: store, server: server)
        let enabled = try #require(enabledResponse["data"] as? [String: Any])
        let request: [String: Any] = ["action": "awayEvents", "principal": principalBody,
            "eventEpoch": UUID().uuidString, "eventCursor": 0,
            "awayActivationID": try #require(enabled["activationID"] as? String),
            "awayRevision": try #require(enabled["revision"] as? Int)]
        let (_, otherEpoch) = try await post(body: request, store: store, server: server)
        #expect((otherEpoch["data"] as? [String: Any])?["gap"] as? Bool == true)
        let oldCursor = try #require(enabled["checkpointCursor"] as? Int)
        for index in 0..<520 { session.mark(status: index.isMultiple(of: 2) ? .executing : .asking) }
        var expired = request
        expired["eventEpoch"] = try #require(enabled["checkpointEpoch"] as? String)
        expired["eventCursor"] = oldCursor
        let (_, result) = try await post(body: expired, store: store, server: server)
        let batch = try #require(result["data"] as? [String: Any])
        #expect(batch["gap"] as? Bool == true && batch["refresh"] as? Bool == true)
        #expect((batch["events"] as? [[String: Any]])?.isEmpty == true)
    }

    @Test func disablingAndReenablingFencesAnInflightHistoryRead() async throws {
        let (_, store, server) = try fixture()
        defer { server.stop(); store.stopPuckObservation(); store.flushPendingSessionSaves() }
        let gate = HeldSlackContext()
        store.slackTerminalContext = gate
        try store.codexRemote.configure(.init(enabled: true, allowed: [principal]))
        try await waitForPuckState { server.listeningPort != nil }
        let id = try #require(store.sessions.first?.id)
        let request = Task { try await post(body: ["action": "context", "principal": principalBody, "sessionID": id], store: store, server: server) }
        await gate.waitUntilStarted()
        try store.codexRemote.configure(.init(enabled: false, allowed: [principal]))
        try store.codexRemote.configure(.init(enabled: true, allowed: [principal]))
        await gate.release()
        let (status, result) = try await request.value
        #expect(status == 409)
        #expect(result["data"] == nil)
        #expect(!String(describing: result).contains("private fixture"))
    }
}
