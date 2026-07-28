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
    private let processTable: @Sendable () -> ProcessTable
    private let historyBackend: any SessionHistoryBackend

    public init(
        persistence: any SessionPersistenceBackend,
        backend: any AgentSupervisorBackend,
        processTable: @escaping @Sendable () -> ProcessTable = { ProcessTable.snapshot() },
        historyBackend: any SessionHistoryBackend = DefaultSessionHistoryBackend()
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
            processTable: processTable()
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
