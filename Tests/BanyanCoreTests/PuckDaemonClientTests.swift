import Foundation
import Testing
@testable import BanyanCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@Test func puckSessionLinkAcceptsOnlyDaemonIDs() {
    #expect(PuckSessionLink.sessionID(from: URL(string: "banyan://puck/session_123")!) == "session_123")
    #expect(PuckSessionLink.sessionID(from: URL(string: "banyan://puck/session-123")!) == "session-123")
    #expect(PuckSessionLink.sessionID(from: URL(string: "banyan://puck/session%2F123")!) == nil)
    #expect(PuckSessionLink.sessionID(from: URL(string: "banyan://puck/session?x=1")!) == nil)
    #expect(PuckSessionLink.sessionID(from: URL(string: "https://puck/session")!) == nil)
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
