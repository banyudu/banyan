import AppKit
import Foundation
import Testing
@testable import Banyan
@testable import BanyanCore

private final class HandoffTerminalBackend: TmuxClientBackend, CodexTUIHandoffBackend, @unchecked Sendable {
    let executableURL = URL(fileURLWithPath: "/usr/bin/false")
    var dead = false
    var receipt: CodexTUIHandoffReceipt?
    var text = "› Ask Codex\n? for shortcuts"
    func hasSession(named: String) -> Bool { true }
    func primaryPaneSnapshot(named: String) -> TmuxPaneSnapshot? {
        .init(paneID: "%1", rootPID: 100, currentCommand: "codex", currentPath: "/tmp", isDead: dead, isInMode: false)
    }
    func captureVisibleText(paneID: String, lineLimit: Int) -> String { text }
    func captureCurrentVisibleText(paneID: String) -> String { text }
    func ensureSession(named: String, cwd: String, command: String, banyanSessionID: String?) throws { Issue.record("Handoff must not launch a command") }
    func killSession(named: String) { Issue.record("Handoff must not kill tmux") }
    func attachArguments(for name: String) -> [String] { [] }
    func configureTerminalTheme(style: String, for sessionName: String?) {}
    func refreshClients(attachedTo: String) {}
    func scrollHistory(paneID: String, lines: Int, up: Bool, onScrollPosition: (@Sendable (Int) -> Void)?) {}
    func freezeTicket(named: String) -> AgentFreezeTicket? { nil }
    func writeFreezeTicket(_ ticket: AgentFreezeTicket?, named: String) throws {}
    func preserveCodexHandoffPane(_ receipt: CodexTUIHandoffReceipt) throws { self.receipt = receipt }
    func codexHandoffReceipt(paneID: String) throws -> CodexTUIHandoffReceipt? { receipt }
}

private final class StoreHandoffInspector: CodexTUIProcessInspecting, @unchecked Sendable {
    let identity = AgentProcessIdentity(pid: 100, startSeconds: 1, startMicroseconds: 2)
    let rollout: String
    var exited = false
    var unavailable = false
    init(rollout: String) { self.rollout = rollout }
    func tree(rootPID: Int32) throws -> [CodexTUIProcess] {
        if unavailable { throw CodexTUIHandoffError.refused("unavailable") }
        return [.init(identity: identity, isCodex: true, openRollouts: [rollout])]
    }
    func hasExited(_ identity: AgentProcessIdentity) throws -> Bool {
        if unavailable { throw CodexTUIHandoffError.refused("unavailable") }
        return exited
    }
}

@MainActor
@Test func codexTUIHandoffStoreExposesPendingCompletedAndDatedExitAndClearsFailedCheck() async throws {
    let f = try PuckStoreFixture(daemon: FakePuckDaemon())
    defer { try? FileManager.default.removeItem(at: f.root) }
    let backend = HandoffTerminalBackend()
    let metadataBackend = TmuxBackend(environment: ["PATH": "/usr/bin:/bin"], workingDirectory: f.project.path,
        socketName: "banyan-handoff-store-test-" + UUID().uuidString)
    let store = f.makeStore(tmuxBackend: metadataBackend, sessionBackend: backend)
    // A custom storage location is discovered from the live descriptor, not
    // guessed from the host's CODEX_HOME or a same-cwd history file.
    let rollout = f.root.appendingPathComponent("custom-rollout.jsonl")
    let meta: CodexJSONValue = .object(["type": .string("session_meta"), "payload": .object([
        "id": .string("exact-thread"), "cwd": .string(f.project.path)])])
    let header = String(decoding: try JSONEncoder().encode(meta), as: UTF8.self) + "\n"
    try (header + "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}\n")
        .write(to: rollout, atomically: true, encoding: .utf8)
    let inspector = StoreHandoffInspector(rollout: rollout.path)
    f.persistence.save([SessionSnapshot(id: "legacy", tmuxSessionName: "banyan-legacy", title: "Legacy",
        reportedTitle: nil, cwd: f.project.path, command: "codex --no-daemon", status: .needInput, tone: .blue,
        agentSessionID: "exact-thread", isSuspended: true, createdAt: Date(), updatedAt: Date())])
    store.loadPersistedSessionsIfNeeded()
    let session = try #require(store.sessions.first as? TerminalSession)
    session.isSuspended = false
    await #expect(throws: CodexTUIHandoffError.self) {
        try await store.codexTUIHandoff(id: session.id, inspector: inspector)
    }
    #expect(store.codexTUIOwnership[session.id]?.state == .turnPending)
    #expect(backend.receipt == nil)
    try (header + "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\"}}\n")
        .write(to: rollout, atomically: true, encoding: .utf8)
    #expect(try await store.codexTUIHandoff(id: session.id, inspector: inspector) == .awaitingCLIExit)
    #expect(backend.receipt?.threadID == "exact-thread")
    backend.dead = true
    inspector.exited = true
    #expect(try await store.codexTUIHandoff(id: session.id, checkOnly: true, inspector: inspector) == .cliExited)
    #expect(store.codexTUIOwnership[session.id]?.observedAt != nil)
    let summary = ControlServer(store: store, host: store.host).summary(session)
    let ownership = try #require(summary["codexTUIOwnership"] as? [String: String])
    #expect(ownership["state"] == "cliExited" && ownership["observedAt"] != nil)
    inspector.unavailable = true
    await #expect(throws: CodexTUIHandoffError.self) {
        try await store.codexTUIHandoff(id: session.id, checkOnly: true, inspector: inspector)
    }
    #expect(store.codexTUIOwnership[session.id] == nil)
    #expect(store.sessions.first === session && session.command == "codex --no-daemon")
    #expect(session.agentSessionID == "exact-thread" && session.cwd == f.project.path)
}
