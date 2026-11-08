import Foundation
import PuckSwift
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum SDKFixtureError: Error { case socket(String), unexpectedMethod, invalidRequest }

func sdkWait(_ semaphore: DispatchSemaphore) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: semaphore.wait(timeout: .now() + 3) == .success)
        }
    }
}

func sdkEventually(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !condition() {
        guard ContinuousClock.now < deadline else { throw SDKFixtureError.socket("timed out waiting for background operations") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

final class SDKBackgroundState: @unchecked Sendable {
    private let lock = NSLock()
    private var activeCount = 0
    private var startedCount = 0
    private var rejectedCount = 0
    private var finishedCount = 0
    private var maximumCount = 0
    var started: Int { lock.withLock { startedCount } }
    var rejected: Int { lock.withLock { rejectedCount } }
    var finished: Int { lock.withLock { finishedCount } }
    var maximumActive: Int { lock.withLock { maximumCount } }
    func begin() { lock.withLock { activeCount += 1; startedCount += 1; maximumCount = max(maximumCount, activeCount) } }
    func end() { lock.withLock { activeCount -= 1; finishedCount += 1 } }
    func reject() { lock.withLock { rejectedCount += 1 } }
}

func sdkCapabilities(major: Int = 2) -> [String: Any] {
    ["protocol": ["major": major, "minor": 0], "engines": ["codex", "native"],
     "default_engine": "codex", "features": ["paged_history", "bounded_events"],
     "engine_capabilities": [["engine": "codex", "owns_coding_loop": true, "replaces_builtin_tools": false,
                              "exact_parked_recovery": false, "paged_history": "engine history", "adding_custom_tools": false]]]
}
func sdkSummary() -> [String: Any] {
    ["id": "fixture-session", "engine": "codex", "provider": "fixture-provider",
     "account": "fixture-seat", "workspace": "/tmp/sdk-project", "cwd": "/tmp/sdk-project",
     "model": "fixture-model", "position": "running", "history_items": 0]
}
func sdkTask() -> [String: Any] {
    [
        "schema": 1, "id": "task-fixture", "revision": 4, "state": "ready_for_decision",
        "source": ["kind": "slack", "external_id": "C1:1700000000.000001"],
        "title": "Fix the fixture", "body": "Keep the wire contract stable.",
        "repository": "owner/repo", "workspace": "/tmp/project", "owner": "U1",
        "priority": "high", "candidate_keys": ["source:slack:C1:1700000000.000001"],
        "acceptance": [["id": "tests", "text": "Tests pass"]],
        "acceptance_hash": "acceptance-hash", "head_sha": "head-sha",
        "capability": [
            "allowed_sources": ["slack"], "repositories": ["owner/repo"],
            "worktree_write": true, "branch_push": true, "pr_create": true,
            "pr_comment": false, "merge": false, "deploy": false,
            "tracker_close": false, "max_attempts": 3, "max_concurrency": 1,
            "budget": ["max_tokens": 10000], "lease_ms": 900000,
        ],
        "attempts": [[
            "id": "attempt-1", "task_id": "task-fixture", "state": "completed",
            "session_id": "session-1", "workspace": "/tmp/project",
            "worktree": "/tmp/project-worktrees/attempt-1",
            "branch": "puck/task-attempt-1", "base_sha": "base-sha",
            "engine": "codex", "provider": "codex", "model": "gpt-6-luna",
            "budget": [:] as [String: Any], "started_at_ms": 1_700_000_000_001,
            "ended_at_ms": 1_700_000_000_002, "heartbeat_at_ms": 1_700_000_000_002,
            "lease_expires_at_ms": 1_700_000_900_000, "evidence_ids": ["evidence-1"],
        ]],
        "current_attempt": "attempt-1",
        "evidence": [[
            "id": "evidence-1", "task_id": "task-fixture", "attempt_id": "attempt-1",
            "kind": "tests", "source": ["kind": "test", "reference": "cargo test"],
            "observed_at_ms": 1_700_000_000_002, "task_revision": 3,
            "acceptance_hash": "acceptance-hash", "head_sha": "head-sha",
            "payload": ["passed": true], "payload_hash": "payload-hash", "stale": false,
        ]],
        "decisions": [[
            "id": "decision-1", "task_id": "task-fixture", "kind": "accept",
            "outcome": "accepted", "actor": ["name": "U1", "kind": "slack"],
            "rationale": "Checks are green", "evidence_ids": ["evidence-1"],
            "evidence_hashes": ["payload-hash"], "task_revision": 3,
            "created_at_ms": 1_700_000_000_003,
        ]],
        "blocker": NSNull(), "next_action": "close the task",
        "slack": [
            "channel": "C1", "thread_ts": "1700000000.000001",
            "last_projected_revision": 4, "last_fingerprint": "ready|attempt-1",
        ],
        "closeout": NSNull(), "created_at_ms": 1_700_000_000_000,
        "updated_at_ms": 1_700_000_000_004,
    ]
}
func sdkEvent(_ cursor: Int, text: String) -> [String: Any] {
    ["cursor": cursor, "data": ["event": "assistant_message", "text": text]]
}
func sdkAttached(cursor: Int, events: [[String: Any]] = []) -> [String: Any] {
    ["summary": sdkSummary(), "cursor": cursor, "events": events, "history_api": false]
}
func sdkPage(_ ids: [Int]) -> PuckHistoryPage {
    PuckHistoryPage(session: "fixture-session", source: "display", items: ids.map {
        PuckHistoryItem(id: "item-\($0)", kind: "assistant", text: "message \($0)")
    }, nextCursor: "older")
}

final class SDKSocketFixture: @unchecked Sendable {
    let path: String
    let detached = DispatchSemaphore(value: 0)
    private let listener: Int32
    private let lock = NSLock()
    private var stopped = false
    private var storedRequests: [[String: Any]] = []
    private var storedFailures: [String] = []
    private var peers: [SDKSocketPeer] = []
    private let handler: (SDKSocketPeer, [String: Any]) throws -> Void
    var requests: [[String: Any]] { lock.withLock { storedRequests } }
    var failures: [String] { lock.withLock { storedFailures } }

    init(handler: @escaping (SDKSocketPeer, [String: Any]) throws -> Void) throws {
        self.handler = handler
        path = "/tmp/puck-sdk-\(UUID().uuidString.prefix(12)).sock"
        #if canImport(Darwin)
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        #else
        listener = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard listener >= 0 else { throw SDKFixtureError.socket("socket") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in raw.copyBytes(from: bytes); raw[bytes.count] = 0 }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0, listen(listener, 16) == 0 else {
            _ = close(listener); _ = unlink(path)
            throw SDKFixtureError.socket("bind/listen")
        }
        Thread { [self] in
            while !lock.withLock({ stopped }) {
                let descriptor = accept(listener, nil, nil)
                guard descriptor >= 0 else { break }
                let peer = SDKSocketPeer(descriptor)
                lock.withLock { peers.append(peer) }
                DispatchQueue.global().async { [self] in
                    defer { peer.closeSocket(); detached.signal() }
                    do {
                        while let request = try peer.readRequest() {
                            lock.withLock { storedRequests.append(request) }
                            try handler(peer, request)
                        }
                    } catch {
                        lock.withLock { storedFailures.append(String(describing: error)) }
                    }
                }
            }
        }.start()
    }

    func stop() {
        let active = lock.withLock { () -> [SDKSocketPeer] in
            guard !stopped else { return [] }
            stopped = true
            _ = shutdown(listener, Int32(SHUT_RDWR))
            _ = close(listener)
            return peers
        }
        active.forEach { $0.disconnect() }
        _ = unlink(path)
    }
    deinit { stop() }
}

final class SDKSocketPeer: @unchecked Sendable {
    private let descriptor: Int32
    private let lock = NSLock()
    private var closed = false
    private var pending = Data()
    init(_ descriptor: Int32) {
        self.descriptor = descriptor
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        #if canImport(Darwin)
        var noSignal: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }
    func readRequest() throws -> [String: Any]? {
        while true {
            guard !lock.withLock({ closed }) else { return nil }
            if let newline = pending.firstIndex(of: 10) {
                let data = Data(pending[..<newline]); pending.removeSubrange(...newline)
                guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw SDKFixtureError.invalidRequest
                }
                return request
            }
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = bytes.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return nil }
            pending.append(contentsOf: bytes.prefix(count))
        }
    }
    func reply(_ request: [String: Any], result: Any) throws {
        try send(["jsonrpc": "2.0", "id": request["id"] ?? 1, "result": result])
    }
    func notify(cursor: Int, kind: String, text: String, transient: Bool = false) throws {
        try send(["jsonrpc": "2.0", "method": "session.event", "params": [
            "session": "fixture-session", "cursor": cursor,
            "data": ["event": kind, "text": text, "transient": transient]
        ]])
    }
    func send(_ value: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: value) + Data([10])
        try sendBytes(data)
    }
    func sendBytes(_ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                #if canImport(Darwin)
                let count = write(descriptor, bytes.baseAddress!.advanced(by: sent), bytes.count - sent)
                #else
                let count = Glibc.send(descriptor, bytes.baseAddress!.advanced(by: sent), bytes.count - sent, Int32(MSG_NOSIGNAL))
                #endif
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw SDKFixtureError.socket("write") }
                sent += count
            }
        }
    }
    func disconnect() { lock.withLock { if !closed { _ = shutdown(descriptor, Int32(SHUT_RDWR)) } } }
    func closeSocket() { lock.withLock { if !closed { closed = true; _ = close(descriptor) } } }
}
