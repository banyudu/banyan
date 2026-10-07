import Foundation
import Testing
@testable import BanyanCore

private final class HandoffBackend: CodexTUIHandoffBackend, @unchecked Sendable {
    var pane: TmuxPaneSnapshot? = .init(paneID: "%1", rootPID: 100, currentCommand: "codex", currentPath: "/tmp", isDead: false, isInMode: false)
    var text = "› Ask Codex\n? for shortcuts"
    var receipt: CodexTUIHandoffReceipt?
    var failPreservation = false
    func hasSession(named: String) -> Bool { pane != nil }
    func primaryPaneSnapshot(named: String) -> TmuxPaneSnapshot? { pane }
    func captureVisibleText(paneID: String, lineLimit: Int) -> String { text }
    func preserveCodexHandoffPane(_ receipt: CodexTUIHandoffReceipt) throws {
        if failPreservation { throw CodexTUIHandoffError.refused("remain-on-exit unavailable") }
        self.receipt = receipt
    }
    func codexHandoffReceipt(paneID: String) throws -> CodexTUIHandoffReceipt? { receipt }
}

private final class HandoffInspector: CodexTUIProcessInspecting, @unchecked Sendable {
    let root = AgentProcessIdentity(pid: 100, startSeconds: 10, startMicroseconds: 1)
    var exited = false
    var unavailable = false
    var openRollout: String
    var replaced = false
    var emptyTree = false
    init(_ path: String) { openRollout = path }
    func tree(rootPID: Int32) throws -> [CodexTUIProcess] {
        if unavailable { throw CodexTUIHandoffError.refused("inspection unavailable") }
        if emptyTree { return [] }
        return [.init(identity: replaced ? .init(pid: 100, startSeconds: 20, startMicroseconds: 1) : root,
                      isCodex: !exited, openRollouts: exited ? [] : [openRollout])]
    }
    func hasExited(_ identity: AgentProcessIdentity) throws -> Bool {
        if unavailable { throw CodexTUIHandoffError.refused("inspection unavailable") }
        if replaced { throw CodexTUIHandoffError.refused("identity changed") }
        return exited
    }
}

private struct HandoffTranscript {
    let root: URL
    let url: URL
    init(events: [String] = ["task_started", "task_complete"]) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-handoff-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        url = root.appendingPathComponent("rollout-thread.jsonl")
        let meta: CodexJSONValue = .object(["type": .string("session_meta"),
            "payload": .object(["id": .string("thread"), "cwd": .string(root.path)])])
        var data = try JSONEncoder().encode(meta)
        data.append(10)
        for event in events {
            data.append(Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"\(event)\"}}\n".utf8))
        }
        try data.write(to: url)
    }
    func prepare(_ backend: HandoffBackend, inspector: HandoffInspector? = nil) throws -> CodexTUIHandoffReceipt {
        try CodexTUIHandoff.prepare(threadID: "thread", cwd: root.path, transcriptURL: url,
            sessionName: "fixture", backend: backend, inspector: inspector ?? HandoffInspector(url.path))
    }
}

@Test func codexTUIHandoffRetainsExactIdentityAndOnlyConfirmsAfterExit() throws {
    let fixture = try HandoffTranscript()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let backend = HandoffBackend()
    let inspector = HandoffInspector(fixture.url.path)
    let original = try Data(contentsOf: fixture.url)
    let receipt = try fixture.prepare(backend, inspector: inspector)
    #expect(receipt.threadID == "thread" && receipt.transcriptPath == fixture.url.path)
    #expect(try CodexTUIHandoff.check(sessionName: "fixture", threadID: "thread", backend: backend,
        inspector: inspector) == .awaitingCLIExit)
    backend.pane = .init(paneID: "%1", rootPID: 100, currentCommand: "codex", currentPath: fixture.root.path,
        isDead: true, isInMode: false)
    inspector.exited = true
    #expect(try CodexTUIHandoff.check(sessionName: "fixture", threadID: "thread", backend: backend,
        inspector: inspector) == .cliExited)
    #expect(try Data(contentsOf: fixture.url) == original)
    #expect(FileManager.default.fileExists(atPath: fixture.root.path))
    #expect(backend.pane != nil)
}

@Test func codexTUIHandoffRefusesRunningQueuedIncompleteAndWrongThreadTranscripts() throws {
    for events in [[], ["task_started"], ["task_started", "task_complete", "task_started"],
                   ["task_complete", "user_message"], ["task_complete", "turn_aborted"]] {
        let fixture = try HandoffTranscript(events: events)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let backend = HandoffBackend()
        #expect(throws: CodexTUIHandoffError.self) { try fixture.prepare(backend) }
        #expect(backend.receipt == nil)
    }
    let fixture = try HandoffTranscript()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    #expect(throws: CodexTUIHandoffError.self) {
        try CodexTUIHandoff.validateCompletedTranscript(fixture.url, threadID: "other", cwd: fixture.root.path)
    }
    #expect(throws: CodexTUIHandoffError.self) {
        try CodexTUIHandoff.validateCompletedTranscript(fixture.url, threadID: "thread", cwd: "/tmp/other")
    }
    let file = try FileHandle(forWritingTo: fixture.url)
    try file.seekToEnd()
    try file.write(contentsOf: Data("{\"type\":".utf8))
    try file.close()
    #expect(throws: CodexTUIHandoffError.self) { try fixture.prepare(HandoffBackend()) }
}

@Test func codexTUIHandoffRefusesVisibleBusyAndPendingRequests() throws {
    let fixture = try HandoffTranscript()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let backend = HandoffBackend()
    for text in ["Working…\nEsc to interrupt", "Would you like to run the following command?\n› 1. Yes, proceed\n  2. No\nPress enter to confirm"] {
        backend.text = text
        #expect(throws: CodexTUIHandoffError.self) { try fixture.prepare(backend) }
        #expect(backend.receipt == nil)
    }
}

@Test func codexTUIHandoffFailureCanRetryAndChangedPaneCannotConfirmRelease() throws {
    let fixture = try HandoffTranscript()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let backend = HandoffBackend()
    backend.failPreservation = true
    #expect(throws: CodexTUIHandoffError.self) { try fixture.prepare(backend) }
    #expect(backend.receipt == nil)
    backend.failPreservation = false
    _ = try fixture.prepare(backend)
    backend.pane = .init(paneID: "%2", rootPID: 200, currentCommand: "sh", currentPath: fixture.root.path,
        isDead: true, isInMode: false)
    #expect(throws: CodexTUIHandoffError.self) {
        try CodexTUIHandoff.check(sessionName: "fixture", threadID: "thread", backend: backend, inspector: HandoffInspector(fixture.url.path))
    }
}

@Test func codexHandoffControlRequiresIdentityAndPost() throws {
    #expect(ControlRoute.resolve(method: "POST", path: "/codex-handoff") == .codexHandoff)
    #expect(ControlRoute.resolve(method: "GET", path: "/codex-handoff") == nil)
    #expect(throws: ControlValidationError.self) { try ControlRoute.codexHandoff.validate(.init()) }
}

@Test func codexTUIHandoffRejectsMismatchedLiveThreadAndUnavailableOrReusedProcess() throws {
    let fixture = try HandoffTranscript()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let backend = HandoffBackend()
    let inspector = HandoffInspector(fixture.url.path + ".different-thread")
    #expect(throws: CodexTUIHandoffError.self) { try fixture.prepare(backend, inspector: inspector) }
    #expect(backend.receipt == nil)
    inspector.openRollout = fixture.url.path
    inspector.unavailable = true
    #expect(throws: CodexTUIHandoffError.self) { try fixture.prepare(backend, inspector: inspector) }
    inspector.unavailable = false
    _ = try fixture.prepare(backend, inspector: inspector)
    inspector.unavailable = true
    #expect(throws: CodexTUIHandoffError.self) {
        try CodexTUIHandoff.check(sessionName: "fixture", threadID: "thread", backend: backend, inspector: inspector)
    }
    inspector.unavailable = false
    inspector.replaced = true
    #expect(throws: CodexTUIHandoffError.self) {
        try CodexTUIHandoff.check(sessionName: "fixture", threadID: "thread", backend: backend, inspector: inspector)
    }
}

@Test func codexTUIHandoffEmptyTreeAndChangedActiveThreadCannotConfirmExit() throws {
    let fixture = try HandoffTranscript()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let backend = HandoffBackend()
    let inspector = HandoffInspector(fixture.url.path)
    _ = try fixture.prepare(backend, inspector: inspector)
    inspector.emptyTree = true
    inspector.exited = true
    #expect(throws: CodexTUIHandoffError.self) {
        try CodexTUIHandoff.check(sessionName: "fixture", threadID: "thread", backend: backend, inspector: inspector)
    }
    inspector.emptyTree = false
    inspector.exited = false
    inspector.openRollout += ".new-thread"
    #expect(throws: CodexTUIHandoffError.self) {
        try CodexTUIHandoff.check(sessionName: "fixture", threadID: "thread", backend: backend, inspector: inspector)
    }
}

@Test func codexTUIHandoffReadsLargeRolloutAndRejectsReplacedTranscriptHeader() throws {
    let fixture = try HandoffTranscript()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let file = try FileHandle(forWritingTo: fixture.url)
    try file.seekToEnd()
    // Force a bounded-tail read that starts within a UTF-8 log row.
    let row = Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"agent_message\",\"text\":\"\(String(repeating: "𐐀", count: 400))\"}}\n".utf8)
    for _ in 0..<800 { try file.write(contentsOf: row) }
    try file.write(contentsOf: Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\"}}\n".utf8))
    try file.close()
    let backend = HandoffBackend()
    let inspector = HandoffInspector(fixture.url.path)
    _ = try fixture.prepare(backend, inspector: inspector)
    let text = try String(contentsOf: fixture.url, encoding: .utf8)
    try text.replacingOccurrences(of: "\"id\":\"thread\"", with: "\"id\":\"different-thread\"")
        .write(to: fixture.url, atomically: true, encoding: .utf8)
    backend.pane = .init(paneID: "%1", rootPID: 100, currentCommand: "codex", currentPath: fixture.root.path,
        isDead: true, isInMode: false)
    inspector.exited = true
    #expect(throws: CodexTUIHandoffError.self) {
        try CodexTUIHandoff.check(sessionName: "fixture", threadID: "thread", backend: backend, inspector: inspector)
    }
}
