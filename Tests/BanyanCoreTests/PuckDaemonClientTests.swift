import Foundation
import Testing
@testable import BanyanCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@Suite struct PuckDaemonClientTests {
    @Test(arguments: [false, true])
    func createUsesDaemonApprovalDefault(throughService: Bool) throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("puck-create-\(UUID().uuidString.prefix(8)).sock").path
        let listener = try listeningPuckSocket(at: path)
        defer { _ = close(listener); _ = unlink(path) }

        let captured = PuckRequestCapture()
        let serverDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { serverDone.signal() }
            let peer = accept(listener, nil, nil)
            guard peer >= 0 else { return }
            defer { _ = close(peer) }
            let capabilities = readPuckRequest(peer)
            guard capabilities?["method"] as? String == "daemon.capabilities" else { return }
            writePuckLines(peer, [#"{"jsonrpc":"2.0","id":1,"result":{"engines":["codex","native"]}}"#])
            captured.record(readPuckRequest(peer))
            writePuckLines(peer, [
                #"{"jsonrpc":"2.0","id":2,"result":{"id":"created","engine":"codex","provider":"codex","account":"seat","workspace":"/tmp","cwd":"/tmp","model":"model","position":"idle"}}"#
            ])
        }

        let client = PuckDaemonClient(socketPath: path)
        let summary: PuckSessionSummary
        if throughService {
            let service: any PuckDaemonService = client
            summary = try service.create(id: "created", provider: "codex", account: nil,
                                         model: nil, workspace: "/tmp")
        } else {
            summary = try client.create(id: "created", provider: "codex", workspace: "/tmp")
        }

        #expect(summary.id == "created")
        #expect(summary.engine == "codex")
        #expect(serverDone.wait(timeout: .now() + 2) == .success)
        let request = try #require(captured.request)
        #expect(request["method"] as? String == "session.create")
        let params = try #require(request["params"] as? [String: Any])
        #expect(params["id"] as? String == "created")
        #expect(params["engine"] as? String == "codex")
        let settings = try #require(params["settings"] as? [String: Any])
        #expect(settings["approval"] == nil)
    }
}

private final class PuckRequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [String: Any]?

    var request: [String: Any]? { lock.withLock { value } }

    func record(_ request: [String: Any]?) {
        lock.withLock { value = request }
    }
}

@Test func puckSessionLinkAcceptsOnlyDaemonIDs() {
    #expect(PuckSessionLink.sessionID(from: URL(string: "banyan://puck/session_123")!) == "session_123")
    #expect(PuckSessionLink.sessionID(from: URL(string: "banyan://puck/session-123")!) == "session-123")
    #expect(PuckSessionLink.sessionID(from: URL(string: "banyan://puck/session%2F123")!) == nil)
    #expect(PuckSessionLink.sessionID(from: URL(string: "banyan://puck/session?x=1")!) == nil)
    #expect(PuckSessionLink.sessionID(from: URL(string: "https://puck/session")!) == nil)
}

@Test func puckPendingQuestionsPreserveChoicesAndValidateTerminalInput() throws {
    let summary = try PuckSessionSummary([
        "id": "shared", "provider": "codex", "account": "seat", "workspace": "/tmp",
        "cwd": "/tmp", "model": "model", "position": "parked",
        "pending_question": [
            "call_id": "ask-1", "expires_at_ms": 999999,
            "questions": [[
                "header": "Files", "question": "Which files?", "multiple": true,
                "custom": true, "default": "1", "options": [
                    ["label": "One", "description": "Use one file."],
                    ["label": "Two", "description": "Use two files."]
                ]
            ]]
        ]
    ])
    let pending = try #require(summary.pendingQuestion)
    #expect(pending.callID == "ask-1")
    #expect(pending.questions[0].options.map(\.label) == ["One", "Two"])
    #expect(PuckQuestionSelection.parse("1,2", for: pending.questions[0])?.labels == ["One", "Two"])
    #expect(PuckQuestionSelection.parse("2,2", for: pending.questions[0]) == nil)
    #expect(PuckQuestionSelection.parse("-9223372036854775808", for: pending.questions[0]) == nil)
    #expect(PuckQuestionSelection.parse("text:Other files", for: pending.questions[0])?.text == "Other files")
    let decoded = try PuckQuestionSelection.decodeJSON("[{\"labels\":[\"One\"],\"text\":null}]")
    #expect(decoded == [PuckQuestionSelection(labels: ["One"])])
}

@Test func puckAttachReplaysEventsThenReceivesLiveNotifications() throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("puck-client-\(UUID().uuidString.prefix(8)).sock").path
    #if canImport(Glibc)
    let listener = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
    #else
    let listener = socket(AF_UNIX, SOCK_STREAM, 0)
    #endif
    #expect(listener >= 0)
    defer { _ = close(listener); _ = unlink(path) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8)
    withUnsafeMutableBytes(of: &address.sun_path) { bytes in
        bytes.copyBytes(from: pathBytes)
        bytes[pathBytes.count] = 0
    }
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    #expect(bound == 0)
    #expect(listen(listener, 1) == 0)

    let serverDone = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        defer { serverDone.signal() }
        let peer = accept(listener, nil, nil)
        guard peer >= 0 else { return }
        defer { _ = close(peer) }
        var request = Data()
        var byte: UInt8 = 0
        while read(peer, &byte, 1) == 1 && byte != 10 { request.append(byte) }
        let object = (try? JSONSerialization.jsonObject(with: request)) as? [String: Any]
        guard object?["method"] as? String == "session.attach",
              let params = object?["params"] as? [String: Any],
              params["session"] as? String == "shared",
              (params["after"] as? NSNumber)?.uint64Value == 4 else { return }
        let reply = """
        {"jsonrpc":"2.0","id":1,"result":{"summary":{"id":"shared","provider":"codex","account":"seat","workspace":"/tmp","cwd":"/tmp","model":"model","position":"idle","pending_approval":null},"cursor":5,"events":[{"cursor":5,"data":{"event":"text_delta","text":"Hello"}}]}}
        {"jsonrpc":"2.0","method":"session.event","params":{"session":"shared","cursor":6,"data":{"event":"text_delta","text":" world"}}}
        """ + "\n"
        _ = reply.withCString { write(peer, $0, reply.utf8.count) }
    }

    let client = PuckDaemonClient(socketPath: path)
    let (connection, attached) = try client.attach("shared", after: 4)
    #expect(attached.summary.id == "shared")
    #expect(attached.batch.cursor == 5)
    #expect(attached.batch.events.map(\.cursor) == [5])
    let live = try connection.nextEvent()
    #expect(live?.cursor == 6)
    #expect(live?.text == " world")
    #expect(serverDone.wait(timeout: .now() + 2) == .success)
}

@Test func puckTranscriptCoalescesStreamedTextWithoutDuplicatingFinalAnswer() throws {
    let events = try [
        ["cursor": 1, "data": ["event": "turn_started"]],
        ["cursor": 2, "data": ["event": "text_delta", "text": "Hello"]],
        ["cursor": 3, "data": ["event": "text_delta", "text": " world"]],
        ["cursor": 4, "data": ["event": "turn_done", "text": "Hello world"]]
    ].map(PuckSessionEvent.init)
    let rendered = PuckTranscript.render(events)
    #expect(rendered.count == 2)
    #expect(rendered.last?.text == "Hello world")
}

@Test func puckReplayFetchesEveryBoundedPage() throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("puck-page-\(UUID().uuidString.prefix(8)).sock").path
    #if canImport(Glibc)
    let listener = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
    #else
    let listener = socket(AF_UNIX, SOCK_STREAM, 0)
    #endif
    #expect(listener >= 0)
    defer { _ = close(listener); _ = unlink(path) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8)
    withUnsafeMutableBytes(of: &address.sun_path) { bytes in
        bytes.copyBytes(from: pathBytes)
        bytes[pathBytes.count] = 0
    }
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    #expect(bound == 0)
    #expect(listen(listener, 2) == 0)
    let serverDone = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        defer { serverDone.signal() }
        for (expectedAfter, cursor) in [(1, 2), (2, 3)] {
            let peer = accept(listener, nil, nil)
            guard peer >= 0 else { return }
            var request = Data()
            var byte: UInt8 = 0
            while read(peer, &byte, 1) == 1 && byte != 10 { request.append(byte) }
            let object = (try? JSONSerialization.jsonObject(with: request)) as? [String: Any]
            guard object?["method"] as? String == "session.events",
                  let params = object?["params"] as? [String: Any],
                  (params["after"] as? NSNumber)?.intValue == expectedAfter else {
                _ = close(peer)
                return
            }
            let reply = """
            {"jsonrpc":"2.0","id":1,"result":{"cursor":3,"events":[{"cursor":\(cursor),"data":{"event":"text_delta","text":"\(cursor)"}}]}}
            """ + "\n"
            _ = reply.withCString { write(peer, $0, reply.utf8.count) }
            _ = close(peer)
        }
    }

    let first = try PuckEventBatch([
        "cursor": 3,
        "events": [["cursor": 1, "data": ["event": "text_delta", "text": "1"]]]
    ])
    let events = try PuckDaemonClient(socketPath: path).replay("shared", initial: first)
    #expect(events.map(\.cursor) == [1, 2, 3])
    #expect(serverDone.wait(timeout: .now() + 2) == .success)
}

private struct EmptyUnifiedSessionSource: SessionListDataSource {
    func loadActiveSessions() -> [SessionSnapshot] { [] }
    func loadHistory(limit: Int) -> [ImportedAgentSession] { [] }
}

@Test func oneDaemonSessionSurvivesThreeFrontendConnectionsAndReconnect() throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("puck-shared-\(UUID().uuidString.prefix(8)).sock").path
    #if canImport(Glibc)
    let listener = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
    #else
    let listener = socket(AF_UNIX, SOCK_STREAM, 0)
    #endif
    #expect(listener >= 0)
    defer { _ = close(listener); _ = unlink(path) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8)
    withUnsafeMutableBytes(of: &address.sun_path) { bytes in
        bytes.copyBytes(from: pathBytes)
        bytes[pathBytes.count] = 0
    }
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    #expect(bound == 0)
    #expect(listen(listener, 5) == 0)

    let summary = #"{"id":"shared","provider":"codex","account":"seat","workspace":"/tmp","cwd":"/tmp","model":"model","position":"idle","pending_approval":null}"#
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        defer { done.signal() }
        for expected in ["session.list", "session.list", "session.list",
                         "session.attach", "session.attach", "session.list"] {
            let peer = accept(listener, nil, nil)
            guard peer >= 0 else { return }
            var request = Data()
            var byte: UInt8 = 0
            while read(peer, &byte, 1) == 1 && byte != 10 { request.append(byte) }
            let object = (try? JSONSerialization.jsonObject(with: request)) as? [String: Any]
            guard object?["method"] as? String == expected else { _ = close(peer); return }
            let result = expected == "session.attach"
                ? #"{"summary":\#(summary),"cursor":0,"events":[]}"#
                : "[\(summary)]"
            let reply = #"{"jsonrpc":"2.0","id":1,"result":\#(result)}"# + "\n"
            _ = reply.withCString { write(peer, $0, reply.utf8.count) }
            _ = close(peer)
        }
    }

    let appClient = PuckDaemonClient(socketPath: path)
    #expect(try appClient.list().map(\.id) == ["shared"])

    var tuiList = SessionListModel(dataSource: EmptyUnifiedSessionSource(),
                                   puckClient: PuckDaemonClient(socketPath: path))
    tuiList.reload()
    #expect(tuiList.selectedPuckSession?.id == "shared")
    #expect(tuiList.visibleRowCount == 1)

    let ctlClient = PuckDaemonClient(socketPath: path)
    #expect(try ctlClient.list().map(\.id) == ["shared"])
    let (connection, attached) = try appClient.attach("shared")
    #expect(attached.summary.id == "shared")
    connection.disconnect()
    let (reconnected, resumed) = try PuckDaemonClient(socketPath: path).attach("shared")
    #expect(resumed.summary.id == attached.summary.id)
    reconnected.disconnect()
    #expect(try PuckDaemonClient(socketPath: path).list().map(\.id) == ["shared"])
    #expect(done.wait(timeout: .now() + 2) == .success)
}

@MainActor
@Test func puckFollowReplaysStreamsAndRefreshesTheSummaryUntilCancelled() async throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("puck-follow-\(UUID().uuidString.prefix(8)).sock").path
    let listener = try listeningPuckSocket(at: path)
    defer { _ = close(listener); _ = unlink(path) }

    @Sendable func summary(_ position: String, history: Int) -> String {
        #"{"id":"shared","provider":"codex","account":"seat","workspace":"/tmp","cwd":"/tmp","model":"model","position":"\#(position)","history_items":\#(history),"pending_approval":null}"#
    }
    let detached = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        let attachPeer = accept(listener, nil, nil)
        guard attachPeer >= 0 else { return }
        defer { _ = close(attachPeer) }
        guard readPuckRequest(attachPeer)?["method"] as? String == "session.attach" else { return }
        writePuckLines(attachPeer, [
            #"{"jsonrpc":"2.0","id":1,"result":{"summary":\#(summary("running", history: 0)),"cursor":5,"events":[{"cursor":5,"data":{"event":"turn_started"}}]}}"#,
            #"{"jsonrpc":"2.0","method":"session.event","params":{"session":"shared","cursor":6,"data":{"event":"turn_done","text":"done"}}}"#
        ])

        // A summary-changing event makes the follower ask for a fresh summary.
        let getPeer = accept(listener, nil, nil)
        guard getPeer >= 0 else { return }
        if readPuckRequest(getPeer)?["method"] as? String == "session.get" {
            writePuckLines(getPeer, [#"{"jsonrpc":"2.0","id":1,"result":\#(summary("idle", history: 1))}"#])
        }
        _ = close(getPeer)

        // Cancelling the follower must close its attachment, or the daemon
        // keeps publishing to a frontend that stopped listening.
        var byte: UInt8 = 0
        while read(attachPeer, &byte, 1) == 1 {}
        detached.signal()
    }

    let log = PuckUpdateLog()
    let stream = PuckDaemonClient(socketPath: path).follow("shared")
    let consumer = Task { @MainActor in
        for try await update in stream {
            log.updates.append(update)
        }
    }
    let deadline = ContinuousClock.now + .seconds(5)
    while log.updates.count < 3, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }

    #expect(log.updates.count == 3)
    guard log.updates.count == 3 else { return consumer.cancel() }
    if case .attached(let attached, let replayed) = log.updates[0] {
        #expect(attached.position == "running")
        #expect(replayed.map(\.cursor) == [5])
    } else {
        Issue.record("expected the attach first, got \(log.updates[0])")
    }
    if case .events(let live) = log.updates[1] {
        #expect(live.map(\.cursor) == [6])
        #expect(live.map(\.kind) == ["turn_done"])
    } else {
        Issue.record("expected live events second, got \(log.updates[1])")
    }
    if case .summary(let refreshed) = log.updates[2] {
        #expect(refreshed.position == "idle")
        #expect(refreshed.historyItems == 1)
    } else {
        Issue.record("expected a refreshed summary third, got \(log.updates[2])")
    }

    consumer.cancel()
    #expect(detached.wait(timeout: .now() + 2) == .success)
}

@Test func puckFollowReportsAnUnreachableDaemon() async {
    let stream = PuckDaemonClient(socketPath: "/nonexistent/banyan-test/puck.sock").follow("shared")
    await #expect(throws: PuckDaemonError.self) {
        for try await _ in stream {}
    }
}

@MainActor
private final class PuckUpdateLog {
    var updates: [PuckSessionUpdate] = []
}

private func listeningPuckSocket(at path: String) throws -> Int32 {
    #if canImport(Glibc)
    let listener = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
    #else
    let listener = socket(AF_UNIX, SOCK_STREAM, 0)
    #endif
    guard listener >= 0 else { throw PuckDaemonError.unavailable("socket") }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8)
    withUnsafeMutableBytes(of: &address.sun_path) { bytes in
        bytes.copyBytes(from: pathBytes)
        bytes[pathBytes.count] = 0
    }
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard bound == 0, listen(listener, 5) == 0 else {
        _ = close(listener)
        throw PuckDaemonError.unavailable("bind")
    }
    return listener
}

private func readPuckRequest(_ peer: Int32) -> [String: Any]? {
    var request = Data()
    var byte: UInt8 = 0
    while read(peer, &byte, 1) == 1 && byte != 10 { request.append(byte) }
    return (try? JSONSerialization.jsonObject(with: request)) as? [String: Any]
}

private func writePuckLines(_ peer: Int32, _ lines: [String]) {
    let reply = lines.joined(separator: "\n") + "\n"
    _ = reply.withCString { write(peer, $0, reply.utf8.count) }
}

@Test @MainActor func puckWatchPreservesEventsAcrossPresenceRepliesOnTheSameSocket() async throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("puck-watch-\(UUID().uuidString.prefix(8)).sock").path
    let listener = try listeningPuckSocket(at: path)
    defer { _ = close(listener); _ = unlink(path) }
    let detached = DispatchSemaphore(value: 0)
    let activeRequest = PuckRequestCapture()
    let declaration = PuckRequestCapture()
    DispatchQueue.global().async {
        let peer = accept(listener, nil, nil)
        guard peer >= 0 else { return }
        defer { _ = close(peer) }
        // Registration starts away, and claims interactivity without renewing
        // that lease. All commands use the very same persistent socket.
        for (id, method) in [(1, "session.watch"), (2, "presence.away"), (3, "session.watch")] {
            let request = readPuckRequest(peer)
            guard request?["method"] as? String == method else { return }
            if id == 3 { declaration.record(request) }
            writePuckLines(peer, [
                #"{"jsonrpc":"2.0","method":"session.event","params":{"cursor":0,"session":"","data":{"event":"presence_changed","present":false}}}"#,
                #"{"jsonrpc":"2.0","id":\#(id),"result":{"watching":true,"window_seconds":300}}"#
            ])
        }
        let listPeer = accept(listener, nil, nil)
        guard listPeer >= 0 else { return }
        guard readPuckRequest(listPeer)?["method"] as? String == "session.list" else { _ = close(listPeer); return }
        writePuckLines(listPeer, [#"{"jsonrpc":"2.0","id":1,"result":[]}"#])
        _ = close(listPeer)
        let away = readPuckRequest(peer)
        guard away?["method"] as? String == "presence.away" else { return }
        writePuckLines(peer, [
            #"{"jsonrpc":"2.0","method":"session.event","params":{"session":"first","cursor":1,"data":{"event":"text_delta","text":"desk"}}}"#,
            #"{"jsonrpc":"2.0","id":4,"result":{"present":false}}"#
        ])
        let active = readPuckRequest(peer)
        activeRequest.record(active)
        guard active?["method"] as? String == "presence.active" else { return }
        writePuckLines(peer, [
            #"{"jsonrpc":"2.0","id":5,"result":{"present":true}}"#,
            #"{"jsonrpc":"2.0","method":"session.event","params":{"session":"second","cursor":1,"data":{"event":"text_delta","text":"away"}}}"#
        ])
        var byte: UInt8 = 0
        while read(peer, &byte, 1) == 1 {}
        detached.signal()
    }
    let observer = PuckDaemonClient(socketPath: path).watch()
    var ids: [String] = []
    var snapshots = 0
    let consumer = Task { @MainActor in
        for try await update in observer.updates {
            switch update {
            case .snapshot: snapshots += 1
            case .event(let id, _): ids.append(id)
            }
        }
    }
    defer { consumer.cancel(); observer.cancel() }
    var deadline = ContinuousClock.now + .seconds(5)
    while ids.count < 1, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(snapshots == 1)
    #expect(ids == ["first"])
    observer.reportPresence(active: true)
    deadline = ContinuousClock.now + .seconds(5)
    while ids.count < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(ids == ["first", "second"])
    let params = try #require(declaration.request?["params"] as? [String: Any])
    #expect((params["client"] as? [String: String])?["capability"] == "interactive")
    #expect(activeRequest.request?["method"] as? String == "presence.active")
    observer.cancel()
    #expect(detached.wait(timeout: .now() + 2) == .success)
}

@Test func puckAskRoutingAndCursorlessLagMarkersDecode() throws {
    let ask = try PuckSessionEvent(["cursor": 3, "data": [
        "event": "blocked_on_question", "route": "interactive", "notify": false
    ]])
    #expect(ask.route == "interactive")
    #expect(ask.notify == false)
    let lag = try PuckSessionEvent(["data": ["event": "lagged", "count": 7]])
    #expect(lag.cursor == 0)
    #expect(lag.displayText == nil)
}
