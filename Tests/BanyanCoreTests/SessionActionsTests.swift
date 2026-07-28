import Foundation
import Testing
@testable import BanyanCore

@Test func sessionActionsCreatesAndPersistsShellSessionsThroughProtocols() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("banyan-actions-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }

    let database = SessionDatabase(
        databaseURL: directory.appendingPathComponent("state.sqlite"),
        legacyJSONURL: directory.appendingPathComponent("sessions.json")
    )
    let backend = SessionActionsTestBackend()
    let catalog = SessionCatalog(
        persistence: database,
        runtime: SessionRuntimeCoordinator(backend: backend)
    )
    let actions = SessionActions(
        idAllocator: UniqueSessionIDAllocator(persistence: database, tmux: backend),
        catalog: catalog,
        history: DefaultSessionHistoryBackend()
    )

    let id = try actions.createShellSession(cwd: "/tmp/project")

    #expect(id == "tui-shell")
    #expect(database.load().first?.cwd == "/tmp/project")
    #expect(backend.events == ["ensure:banyan-tui-shell"])
}

@Test func sessionActionsUsesInjectedHistoryBackend() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("banyan-history-actions-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }

    let database = SessionDatabase(
        databaseURL: directory.appendingPathComponent("state.sqlite"),
        legacyJSONURL: directory.appendingPathComponent("sessions.json")
    )
    let backend = SessionActionsTestBackend()
    let actions = SessionActions(
        idAllocator: UniqueSessionIDAllocator(persistence: database, tmux: backend),
        catalog: SessionCatalog(
            persistence: database,
            runtime: SessionRuntimeCoordinator(backend: backend)
        ),
        history: StubHistoryBackend()
    )
    let item = ImportedAgentSession(
        id: "history-codex-original",
        provider: .codex,
        sourceID: "original",
        title: "Injected history",
        cwd: "/tmp/project",
        transcriptURL: directory.appendingPathComponent("original.jsonl"),
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: 2)
    )

    let trimmed = try actions.resumeHistory(item, trimmed: true)

    #expect(trimmed)
    #expect(database.load().first?.command == "fake-agent --resume trimmed-id")
}

private final class SessionActionsTestBackend: TmuxSessionLifecycleBackend, @unchecked Sendable {
    var events: [String] = []

    func hasSession(named name: String) -> Bool {
        events.contains("ensure:\(name)")
    }

    func primaryPaneSnapshot(named name: String) -> TmuxPaneSnapshot? { nil }
    func captureVisibleText(paneID: String, lineLimit: Int) -> String { "" }

    func ensureSession(named name: String, cwd: String, command: String) throws {
        events.append("ensure:\(name)")
    }

    func killSession(named name: String) {
        events.append("kill:\(name)")
    }
}

private struct StubHistoryBackend: SessionHistoryBackend {
    func load(maxPerProvider limit: Int) -> [ImportedAgentSession] { [] }

    func sourceID(fromImportedSessionID id: String, provider: CodingAgentProvider) -> String? {
        "original"
    }

    func resumeCommand(
        provider: CodingAgentProvider,
        sourceID: String,
        cwd: String,
        prompt: String?
    ) -> String? {
        "fake-agent --resume \(sourceID)"
    }

    func prepareTrimmedTranscript(
        provider: CodingAgentProvider,
        sourceID: String,
        cwd: String,
        transcriptURL: URL?
    ) -> String? {
        "trimmed-id"
    }
}
