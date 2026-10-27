import AppKit
import BanyanCore
import Foundation
import Testing
@testable import Banyan

@Test @MainActor func explicitResumeIdentityRoundTrip() async throws {
    let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = fixture.makeStore(historyBackend: DefaultSessionHistoryBackend(homeDirectory: fixture.home))
    let session = store.spawn(title: "Pinned conversation", cwd: fixture.project.path,
        command: "codex resume thread-a", select: false)
    #expect(session.agentProvider == .codex)
    #expect(session.agentSessionID == "thread-a")
    let now = session.createdAt
    func history(_ id: String, _ created: Date) -> ImportedAgentSession {
        ImportedAgentSession(id: id, provider: .codex, sourceID: id, title: id,
            agentGeneratedTitle: id, cwd: fixture.project.path,
            transcriptURL: fixture.root.appendingPathComponent(id), createdAt: created, updatedAt: now)
    }
    let a = history("thread-a", now.addingTimeInterval(-86_400))
    let b = history("thread-b", now.addingTimeInterval(-16))
    store.refreshLiveAgentTitles(from: [b])
    #expect(session.agentSessionID == "thread-a")
    store.refreshLiveAgentTitles(from: [a, b])
    #expect(session.agentSessionID == "thread-a")
    #expect(session.displayTitle == "Pinned conversation")
    store.saveSessions()
    store.flushPendingSessionSaves()
    #expect(fixture.persistence.load().first { $0.id == session.id }?.agentSessionID == "thread-a")
    let restored = fixture.makeStore(historyBackend: DefaultSessionHistoryBackend(homeDirectory: fixture.home))
    restored.loadPersistedSessionsIfNeeded()
    let row = try #require(restored.sessions.first { $0.id == session.id } as? TerminalSession)
    #expect(row.agentSessionID == "thread-a")
    restored.refreshLiveAgentTitles(from: [a, b])
    #expect(row.agentSessionID == "thread-a")
    #expect(row.displayTitle == "Pinned conversation")
    row.needsRecovery = true
    row.isProcessStarted = false
    try restored.recover(id: row.id, select: false)
    #expect(row.agentSessionID == "thread-a")
    #expect(row.command == AgentSessionHistory.resumeCommand(provider: .codex, sourceID: "thread-a", cwd: fixture.project.path))
    try await waitForPuckState { !session.backingLaunchInFlight && !row.backingLaunchInFlight }
    store.flushPendingSessionSaves()
    restored.flushPendingSessionSaves()
}

@Test @MainActor func explicitResumeIdentityResetAllowsRebinding() async throws {
    let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = fixture.makeStore()
    let row = store.spawn(cwd: fixture.project.path, command: "codex resume thread-a", select: false)
    row.noteUserSubmittedInput("/new")
    #expect(row.agentSessionID == nil)
    let now = Date()
    let b = ImportedAgentSession(id: "b", provider: .codex, sourceID: "thread-b", title: "b",
        cwd: fixture.project.path, transcriptURL: fixture.root.appendingPathComponent("b"), createdAt: now, updatedAt: now)
    store.refreshLiveAgentTitles(from: [b])
    #expect(row.agentSessionID == "thread-b")
    try await waitForPuckState { !row.backingLaunchInFlight }
    store.flushPendingSessionSaves()
}
