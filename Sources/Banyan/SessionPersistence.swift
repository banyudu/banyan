import BanyanCore
import Foundation

struct WorkspaceSnapshot {
    let selectedSessionID: String?
    let sortMode: SortMode
    let terminalTheme: TerminalTheme
    let terminalFontFamily: String
    let terminalFontSize: Double
    let enableCodexAppServerMode: Bool
    /// How long a closed session stays in `state.sqlite`. `0` keeps everything.
    let sessionRetentionDays: Int
    var enableNativeCodex = false
}

struct LinearIssueListCacheSnapshot: Codable {
    let issues: [LinearIssueSummary]
    let workflowStates: [LinearWorkflowState]?
    let selectedIssueID: String?
    let updatedAt: Date
}

/// Persisted `#123` reference lookups for `GitHubReferenceCache`. A nil `url`
/// is a number the repository did not contain when it was checked.
struct GitHubReferenceCacheSnapshot: Codable {
    struct Entry: Codable {
        let groupID: String
        let number: Int
        let url: String?
        let checkedAt: Date
    }

    let entries: [Entry]
}

/// macOS-specific facade for the shared session database. It owns only the
/// serialization policy for workspace preferences and Linear cache data.
protocol SessionStorePersistenceBackend: SessionPersistenceBackend {
    /// Deletes closed sessions older than the retention window, returning how
    /// many went. Separate from `save` on purpose — see
    /// `SessionDatabase.pruneExpiredSessions`.
    @discardableResult
    func pruneExpiredSessions(retentionDays: Int) -> Int
    func saveSession(_ snapshot: SessionSnapshot, sortOrder: Int)
    func loadWorkspace(defaults: WorkspaceSnapshot) -> WorkspaceSnapshot
    func saveWorkspace(_ workspace: WorkspaceSnapshot)
    func loadLinearIssueListCache() -> LinearIssueListCacheSnapshot?
    func saveLinearIssueListCache(_ snapshot: LinearIssueListCacheSnapshot)
    func loadGitHubReferenceCache() -> GitHubReferenceCacheSnapshot?
    func saveGitHubReferenceCache(_ snapshot: GitHubReferenceCacheSnapshot)
    /// Daemon sessions removed from Banyan. `puckd` keeps them, so the next
    /// listing would otherwise bring them back.
    func loadDismissedPuckSessionIDs() -> Set<String>
    func saveDismissedPuckSessionIDs(_ ids: Set<String>)
}

struct SessionPersistence: SessionStorePersistenceBackend, Sendable {
    private static let linearIssueListCacheKey = "linearIssueListCache"
    private static let githubReferenceCacheKey = "githubReferenceCache"
    private static let dismissedPuckSessionIDsKey = "dismissedPuckSessionIDs"

    private let sessionDatabase: SessionDatabase

    init(
        databaseURL: URL,
        legacyJSONURL: URL
    ) {
        self.sessionDatabase = SessionDatabase(databaseURL: databaseURL, legacyJSONURL: legacyJSONURL)
    }

    func load() -> [SessionSnapshot] {
        sessionDatabase.load()
    }

    func save(_ snapshots: [SessionSnapshot]) {
        sessionDatabase.save(snapshots)
    }

    @discardableResult
    func pruneExpiredSessions(retentionDays: Int) -> Int {
        sessionDatabase.pruneExpiredSessions(retentionDays: retentionDays)
    }

    func saveSession(_ snapshot: SessionSnapshot, sortOrder: Int) {
        sessionDatabase.saveSession(snapshot, sortOrder: sortOrder)
    }

    func loadWorkspace(defaults: WorkspaceSnapshot) -> WorkspaceSnapshot {
        let state = sessionDatabase.loadState()
        return WorkspaceSnapshot(
            selectedSessionID: state["selectedSessionID"] ?? defaults.selectedSessionID,
            sortMode: state["sortMode"].flatMap(SortMode.init(rawValue:)) ?? defaults.sortMode,
            terminalTheme: TerminalTheme.fromPersistedRawValue(state["terminalTheme"]) ?? defaults.terminalTheme,
            terminalFontFamily: state["terminalFontFamily"] ?? defaults.terminalFontFamily,
            terminalFontSize: state["terminalFontSize"].flatMap(Double.init) ?? defaults.terminalFontSize,
            enableCodexAppServerMode: state["enableCodexAppServerMode"].flatMap(Bool.init) ?? defaults.enableCodexAppServerMode,
            sessionRetentionDays: state["sessionRetentionDays"].flatMap(Int.init) ?? defaults.sessionRetentionDays,
            enableNativeCodex: state["enableNativeCodex"].flatMap(Bool.init) ?? defaults.enableNativeCodex
        )
    }

    func saveWorkspace(_ workspace: WorkspaceSnapshot) {
        let values: [String: String?] = [
            "selectedSessionID": workspace.selectedSessionID,
            "sortMode": workspace.sortMode.rawValue,
            "terminalTheme": workspace.terminalTheme.rawValue,
            "terminalFontFamily": workspace.terminalFontFamily,
            "terminalFontSize": String(workspace.terminalFontSize),
            "enableCodexAppServerMode": String(workspace.enableCodexAppServerMode),
            "enableNativeCodex": String(workspace.enableNativeCodex),
            "sessionRetentionDays": String(workspace.sessionRetentionDays)
        ]
        sessionDatabase.saveState(values)
    }

    func loadDismissedPuckSessionIDs() -> Set<String> {
        guard let rawIDs = sessionDatabase.loadState()[Self.dismissedPuckSessionIDsKey],
              let data = rawIDs.data(using: .utf8),
              let ids = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(ids)
    }

    func saveDismissedPuckSessionIDs(_ ids: Set<String>) {
        guard let data = try? JSONEncoder().encode(ids.sorted()),
              let rawIDs = String(data: data, encoding: .utf8) else { return }
        sessionDatabase.saveState([Self.dismissedPuckSessionIDsKey: rawIDs])
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

    func loadGitHubReferenceCache() -> GitHubReferenceCacheSnapshot? {
        guard let rawCache = sessionDatabase.loadState()[Self.githubReferenceCacheKey],
              let data = rawCache.data(using: .utf8) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(GitHubReferenceCacheSnapshot.self, from: data)
    }

    func saveGitHubReferenceCache(_ snapshot: GitHubReferenceCacheSnapshot) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot),
              let rawCache = String(data: data, encoding: .utf8) else { return }
        sessionDatabase.saveState([Self.githubReferenceCacheKey: rawCache])
    }
}
