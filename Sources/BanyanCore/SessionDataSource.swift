import Foundation

/// Loads persisted sessions and reconciles them with live tmux/process state.
/// Frontends decide how the resulting rows are rendered or selected.
public struct SessionDataSource: Sendable {
    private let persistence: any SessionPersistenceBackend
    private let backend: any AgentSupervisorBackend

    public init(
        persistence: any SessionPersistenceBackend,
        backend: any AgentSupervisorBackend
    ) {
        self.persistence = persistence
        self.backend = backend
    }

    public func loadActiveSessions() -> [SessionSnapshot] {
        let stored = persistence.load()
        let synchronizer = SessionStatusSynchronizer(
            backend: backend,
            processTable: ProcessTable.snapshot()
        )
        let updated = synchronizer.synchronize(stored)
        if updated != stored {
            persistence.save(updated)
        }
        return updated.filter { $0.status != .closed }
    }

    public func loadHistory(limit: Int = 30) -> [ImportedAgentSession] {
        AgentSessionHistoryImporter.load(maxPerProvider: limit)
    }
}
