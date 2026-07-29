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
        processTable: EmptyModelProcessTableProvider(),
        historyBackend: ModelHistoryBackend(history: history)
    )
    var model = SessionListModel(dataSource: dataSource)

    model.toggleHistory()
    model.reload()

    #expect(model.selectedHistory == history)
    #expect(model.visibleRowCount == 1)
}

@Test func sessionListModelFiltersHistoryAcrossTitleProviderAndDirectory() {
    let now = Date(timeIntervalSince1970: 100)
    let matching = ImportedAgentSession(
        id: "history-codex-match",
        provider: .codex,
        sourceID: "match",
        title: "Review parser",
        cwd: "/tmp/banyan-project",
        transcriptURL: URL(fileURLWithPath: "/tmp/match.jsonl"),
        createdAt: now,
        updatedAt: now
    )
    let dataSource = SessionDataSource(
        persistence: ModelTestPersistence(),
        backend: ModelTestBackend(),
        processTable: EmptyModelProcessTableProvider(),
        historyBackend: ModelHistoryBackend(history: matching)
    )
    var model = SessionListModel(dataSource: dataSource)

    model.toggleHistory()
    model.setHistoryFilter("banyan-project")
    model.reload()

    #expect(model.selectedHistory == matching)
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

private struct EmptyModelProcessTableProvider: ProcessTableProvider {
    func snapshot() -> ProcessTable { ProcessTable(rows: []) }
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
