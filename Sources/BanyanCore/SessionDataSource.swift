import Foundation

/// Loads persisted sessions and reconciles them with live tmux/process state.
/// Frontends decide how the resulting rows are rendered or selected.
public struct SessionDataSource: Sendable {
    private let persistence: any SessionPersistenceBackend
    private let backend: any AgentSupervisorBackend
    private let processTable: @Sendable () -> ProcessTable
    private let historyLoader: @Sendable (Int) -> [ImportedAgentSession]

    public init(
        persistence: any SessionPersistenceBackend,
        backend: any AgentSupervisorBackend,
        processTable: @escaping @Sendable () -> ProcessTable = { ProcessTable.snapshot() },
        historyLoader: @escaping @Sendable (Int) -> [ImportedAgentSession] = { limit in
            AgentSessionHistoryImporter.load(maxPerProvider: limit)
        }
    ) {
        self.persistence = persistence
        self.backend = backend
        self.processTable = processTable
        self.historyLoader = historyLoader
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
        historyLoader(limit)
    }
}
