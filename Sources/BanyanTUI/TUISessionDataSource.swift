import BanyanCore

struct TUISessionDataSource {
    let database: SessionDatabase
    let tmux: TmuxBackend

    func loadActiveSessions() -> [SessionSnapshot] {
        let stored = database.load()
        let synchronizer = SessionStatusSynchronizer(
            backend: tmux,
            processTable: ProcessTable.snapshot()
        )
        let updated = synchronizer.synchronize(stored)
        if updated != stored { database.save(updated) }
        return updated.filter { $0.status != .closed }
    }

    func loadHistory(limit: Int = 30) -> [ImportedAgentSession] {
        AgentSessionHistoryImporter.load(maxPerProvider: limit)
    }
}
