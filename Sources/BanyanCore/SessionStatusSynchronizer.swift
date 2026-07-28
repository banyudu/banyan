import Foundation

/// Reconciles persisted session state with the live tmux pane and process tree.
/// Frontends can use the result as their display model and persist it when needed.
public struct SessionStatusSynchronizer: Sendable {
    private let backend: any AgentSupervisorBackend
    private let processDescendants: @Sendable (Int) -> [ProcessInfoRow]
    private let sessionName: @Sendable (SessionSnapshot) -> String

    public init(
        backend: any AgentSupervisorBackend,
        processDescendants: @escaping @Sendable (Int) -> [ProcessInfoRow],
        sessionName: @escaping @Sendable (SessionSnapshot) -> String = { snapshot in
            snapshot.tmuxSessionName ?? TmuxBackend.sessionName(for: snapshot.id)
        }
    ) {
        self.backend = backend
        self.processDescendants = processDescendants
        self.sessionName = sessionName
    }

    public func synchronize(_ snapshots: [SessionSnapshot]) -> [SessionSnapshot] {
        let supervisor = AgentSupervisor(
            backend: backend,
            processDescendants: processDescendants
        )

        return snapshots.map { session in
            let tmuxSessionName = sessionName(session)
            guard session.status != .closed,
                  backend.hasSession(named: tmuxSessionName),
                  let result = supervisor.inspect(
                      tmuxSessionName: tmuxSessionName,
                      launchCommand: session.command,
                      currentStatus: session.status
                  ),
                  result.status != .closed,
                  result.status != session.status || result.tone != session.tone else {
                return session
            }
            return session.updating(status: result.status, tone: result.tone)
        }
    }
}
