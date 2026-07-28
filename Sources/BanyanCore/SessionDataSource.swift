import Foundation

public protocol SessionListDataSource: Sendable {
    func loadActiveSessions() -> [SessionSnapshot]
    func loadHistory(limit: Int) -> [ImportedAgentSession]
}

/// Loads persisted sessions and reconciles them with live tmux/process state.
/// Frontends decide how the resulting rows are rendered or selected.
public struct SessionDataSource: Sendable, SessionListDataSource {
    private let persistence: any SessionPersistenceBackend
    private let backend: any AgentSupervisorBackend
    private let processTable: any ProcessTableProvider
    private let historyBackend: any SessionHistoryBackend

    public init(
        persistence: any SessionPersistenceBackend,
        backend: any AgentSupervisorBackend,
        processTable: any ProcessTableProvider,
        historyBackend: any SessionHistoryBackend
    ) {
        self.persistence = persistence
        self.backend = backend
        self.processTable = processTable
        self.historyBackend = historyBackend
    }

    public func loadActiveSessions() -> [SessionSnapshot] {
        let stored = persistence.load()
        let synchronizer = SessionStatusSynchronizer(
            backend: backend,
            processTable: processTable.snapshot()
        )
        let updated = synchronizer.synchronize(stored)
        if updated != stored {
            persistence.save(updated)
        }
        return updated.filter { $0.status != .closed }
    }

    public func loadHistory(limit: Int = 30) -> [ImportedAgentSession] {
        historyBackend.load(maxPerProvider: limit)
    }
}
