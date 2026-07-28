import Foundation
import Testing
@testable import BanyanCore

@Test func sessionListModelLoadsHistoryOnDemandAndSelectsRows() {
    let now = Date(timeIntervalSince1970: 100)
    let history = ImportedAgentSession(
        id: "history-codex-one",
        provider: .codex,
        sourceID: "one",
        title: "One",
        cwd: "/tmp",
        transcriptURL: URL(fileURLWithPath: "/tmp/one.jsonl"),
        createdAt: now,
        updatedAt: now
    )
    let persistence = ModelTestPersistence()
    let dataSource = SessionDataSource(
        persistence: persistence,
        backend: ModelTestBackend(),
        processTable: { ProcessTable(rows: []) },
        historyBackend: ModelHistoryBackend(history: history)
    )
    var model = SessionListModel(dataSource: dataSource)

    model.toggleHistory()
    model.reload()

    #expect(model.selectedHistory == history)
    #expect(model.visibleRowCount == 1)
}

private final class ModelTestPersistence: SessionPersistenceBackend, @unchecked Sendable {
    func load() -> [SessionSnapshot] { [] }
    func save(_ snapshots: [SessionSnapshot]) {}
}

private struct ModelTestBackend: AgentSupervisorBackend {
    func hasSession(named name: String) -> Bool { false }
    func primaryPaneSnapshot(named name: String) -> TmuxPaneSnapshot? { nil }
    func captureVisibleText(paneID: String, lineLimit: Int) -> String { "" }
}

private struct ModelHistoryBackend: SessionHistoryBackend {
    let history: ImportedAgentSession

    func load(maxPerProvider limit: Int) -> [ImportedAgentSession] { [history] }
    func sourceID(fromImportedSessionID id: String, provider: CodingAgentProvider) -> String? { nil }
    func resumeCommand(
        provider: CodingAgentProvider,
        sourceID: String,
        cwd: String,
        prompt: String?
    ) -> String? { nil }
    func prepareTrimmedTranscript(
        provider: CodingAgentProvider,
        sourceID: String,
        cwd: String,
        transcriptURL: URL?
    ) -> String? { nil }
}
