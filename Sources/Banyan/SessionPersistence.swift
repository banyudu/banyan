import BanyanCore
import Foundation

struct WorkspaceSnapshot {
    let selectedSessionID: String?
    let sortMode: SortMode
    let terminalTheme: TerminalTheme
    let terminalFontFamily: String
    let terminalFontSize: Double
}

struct LinearIssueListCacheSnapshot: Codable {
    let issues: [LinearIssueSummary]
    let workflowStates: [LinearWorkflowState]?
    let selectedIssueID: String?
    let updatedAt: Date
}

/// macOS-specific facade for the shared session database. It owns only the
/// serialization policy for workspace preferences and Linear cache data.
struct SessionPersistence: SessionPersistenceBackend {
    private static let linearIssueListCacheKey = "linearIssueListCache"

    private let sessionDatabase: SessionDatabase

    init(
        databaseURL: URL = SessionDatabase.defaultDatabaseURL(),
        legacyJSONURL: URL = SessionDatabase.defaultLegacyJSONURL()
    ) {
        self.sessionDatabase = SessionDatabase(databaseURL: databaseURL, legacyJSONURL: legacyJSONURL)
    }

    func load() -> [SessionSnapshot] {
        sessionDatabase.load()
    }

    func save(_ snapshots: [SessionSnapshot]) {
        sessionDatabase.save(snapshots)
    }

    func loadWorkspace(defaults: WorkspaceSnapshot) -> WorkspaceSnapshot {
        let state = sessionDatabase.loadState()
        return WorkspaceSnapshot(
            selectedSessionID: state["selectedSessionID"] ?? defaults.selectedSessionID,
            sortMode: state["sortMode"].flatMap(SortMode.init(rawValue:)) ?? defaults.sortMode,
            terminalTheme: TerminalTheme.fromPersistedRawValue(state["terminalTheme"]) ?? defaults.terminalTheme,
            terminalFontFamily: state["terminalFontFamily"] ?? defaults.terminalFontFamily,
            terminalFontSize: state["terminalFontSize"].flatMap(Double.init) ?? defaults.terminalFontSize
        )
    }

    func saveWorkspace(_ workspace: WorkspaceSnapshot) {
        let values: [String: String?] = [
            "selectedSessionID": workspace.selectedSessionID,
            "sortMode": workspace.sortMode.rawValue,
            "terminalTheme": workspace.terminalTheme.rawValue,
            "terminalFontFamily": workspace.terminalFontFamily,
            "terminalFontSize": String(workspace.terminalFontSize)
        ]
        sessionDatabase.saveState(values)
    }

    func loadLinearIssueListCache() -> LinearIssueListCacheSnapshot? {
        guard let rawCache = sessionDatabase.loadState()[Self.linearIssueListCacheKey],
              let data = rawCache.data(using: .utf8) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LinearIssueListCacheSnapshot.self, from: data)
    }

    func saveLinearIssueListCache(_ snapshot: LinearIssueListCacheSnapshot) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot),
              let rawCache = String(data: data, encoding: .utf8) else { return }
        sessionDatabase.saveState([Self.linearIssueListCacheKey: rawCache])
    }
}
