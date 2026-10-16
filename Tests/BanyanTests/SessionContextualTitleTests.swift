import AppKit
import BanyanCore
import Foundation
import Testing
@testable import Banyan

@MainActor
private func titleSession(_ id: String) -> TerminalSession {
    TerminalSession(id: id, title: "project", cwd: "/tmp/project", command: "codex", status: .needInput,
        displayContext: SessionDisplayLabel.historicalContext(cwd: "/tmp/project", homeDirectory: "/Users/example"),
        theme: .system, tmuxBackend: banyanTestTmuxBackend, telemetry: banyanTestTelemetry, host: banyanTestHost)
}

@Test @MainActor func contextualTitlesDistinguishIdenticalPromptsAndSurviveHistoryRefreshes() {
    let first = titleSession("first")
    let second = titleSession("second")
    for session in [first, second] { session.markFirstPromptTitle("what happened on this https://example.com/event") }
    #expect(first.displayTitle == second.displayTitle)
    #expect(first.updateContextualTitle("Checkout timeout: exhausted DB pool"))
    #expect(second.updateContextualTitle("Uploads rejected: expired signing key"))
    for session in [first, second] {
        session.markFirstPromptTitle("what happened on this https://example.com/event")
        session.markAgentGeneratedTitle("Investigate event")
        session.refreshGeneratedTitle()
    }
    #expect(first.displayTitle == "Checkout timeout: exhausted DB pool")
    #expect(second.displayTitle == "Uploads rejected: expired signing key")
    #expect(first.updateContextualTitle("Checkout recovered after pool limit fix"))
    #expect(first.displayTitle == "Checkout recovered after pool limit fix")
    #expect(first.isTitlePinned == false)
}

@Test @MainActor func contextualTitlesNeverOverrideManualRenamesAndClearWithConversation() {
    let session = titleSession("manual")
    session.mark(title: "Keep this name")
    #expect(!session.updateContextualTitle("A new diagnosis"))
    #expect(session.displayTitle == "Keep this name")
    let reset = titleSession("reset")
    reset.updateContextualTitle("Old diagnosis")
    reset.noteUserSubmittedInput("/clear")
    #expect(reset.contextualTitle == nil)
    reset.updateContextualTitle("Next investigation")
    reset.noteConversationResetFromTranscript()
    #expect(reset.contextualTitle == nil)
    let renamed = titleSession("renamed")
    renamed.updateContextualTitle("Automatic diagnosis")
    renamed.mark(title: "Codex")
    #expect(renamed.displayTitle == "Codex")
    #expect(!renamed.updateContextualTitle("Another diagnosis"))
}

@Test @MainActor func contextualTitleRoundTripsDatabaseJSONStoreAndAuthenticatedCLI() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("banyan-context-title-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = SessionPersistence(databaseURL: root.appendingPathComponent("state.sqlite"), legacyJSONURL: root.appendingPathComponent("sessions.json"))
    let original = titleSession("saved")
    original.updateContextualTitle("Checkout timeout: exhausted DB pool")
    original.status = .closed
    original.updatedAt = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    let snapshot = original.persistenceSnapshot
    #expect(snapshot.updating(status: .needInput).contextualTitle == original.contextualTitle)
    #expect(try JSONDecoder().decode(SessionSnapshot.self, from: JSONEncoder().encode(snapshot)) == snapshot)
    persistence.save([snapshot])
    #expect(persistence.load().first?.contextualTitle == snapshot.contextualTitle)
    let store = SessionStore(persistence: persistence, tmuxBackend: banyanTestTmuxBackend, sessionBackend: banyanTestTmuxBackend,
        processTable: ContextTitleProcesses(), historyBackend: DefaultSessionHistoryBackend(homeDirectory: root),
        detector: AgentStateDetector(rules: []), host: banyanTestHost, telemetry: banyanTestTelemetry, attentionNotifier: AttentionNotifier())
    store.loadPersistedSessionsIfNeeded()
    #expect(store.sessions.first?.contextualTitle == original.contextualTitle)
    #expect(store.sessions.first?.displayTitle == original.displayTitle)
    let host = HostRuntimeContext(environment: ["BANYAN_FIXTURE_DATA_HOME": root.path, "PATH": "/usr/bin:/bin"],
        homeDirectory: root, currentDirectory: root.path)
    let server = ControlServer(store: store, host: host, port: .any)
    defer { server.stop() }
    server.start()
    try await waitForPuckState { server.listeningPort != nil }
    let port = try #require(server.listeningPort)
    let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let cli = try #require([".build/out/Products/Debug/banyanctl", ".build/debug/banyanctl"]
        .map { package.appendingPathComponent($0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) })
    var environment = host.environment
    environment["BANYAN_FIXTURE_CONTROL_URL"] = "http://127.0.0.1:\(port)"
    let updated = try await SubprocessRunner.runAsync(arguments: [cli.path, "session", "title", "--id", "saved", "--title", "Checkout pool limit fixed"],
        cwd: root.path, environment: environment, timeout: 10, standardInput: FileHandle.nullDevice)
    #expect(updated.terminationStatus == 0, "\(String(decoding: updated.standardError, as: UTF8.self))")
    #expect(store.sessions.first?.displayTitle == "Checkout pool limit fixed")
    try store.mark(id: "saved", title: "My pinned title")
    let preserved = try await SubprocessRunner.runAsync(arguments: [cli.path, "session", "title", "--id", "saved", "--title", "Another finding"],
        cwd: root.path, environment: environment, timeout: 10, standardInput: FileHandle.nullDevice)
    #expect(preserved.terminationStatus == 0)
    #expect(String(decoding: preserved.standardOutput, as: UTF8.self).contains("Manual session title preserved"))
    #expect(store.sessions.first?.displayTitle == "My pinned title")
    store.flushPendingSessionSaves()
}

private struct ContextTitleProcesses: ProcessTableProvider {
    func snapshot() -> ProcessTable { ProcessTable(rows: []) }
}
