import Foundation

public struct SessionStatusObservationInput: Sendable {
    public let id: String
    public let tmuxSessionName: String
    public let command: String
    public let status: SessionStatus
    public let isAwaitingAttach: Bool

    public init(
        id: String,
        tmuxSessionName: String,
        command: String,
        status: SessionStatus,
        isAwaitingAttach: Bool
    ) {
        self.id = id
        self.tmuxSessionName = tmuxSessionName
        self.command = command
        self.status = status
        self.isAwaitingAttach = isAwaitingAttach
    }
}

public struct SessionStatusObservation: Sendable {
    public let id: String
    public let status: SessionStatus
    public let tone: SessionTone
    public let provider: CodingAgentProvider?
    public let currentPath: String?

    public init(
        id: String,
        status: SessionStatus,
        tone: SessionTone,
        provider: CodingAgentProvider?,
        currentPath: String?
    ) {
        self.id = id
        self.status = status
        self.tone = tone
        self.provider = provider
        self.currentPath = currentPath
    }
}

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

    /// Builds a synchronizer from one process-table snapshot. Keeping the
    /// snapshot outside the descendant lookup avoids rescanning the process
    /// table once per session during a refresh.
    public init(
        backend: any AgentSupervisorBackend,
        processTable: ProcessTable,
        sessionName: @escaping @Sendable (SessionSnapshot) -> String = { snapshot in
            snapshot.tmuxSessionName ?? TmuxBackend.sessionName(for: snapshot.id)
        }
    ) {
        self.init(
            backend: backend,
            processDescendants: { rootPID in processTable.descendants(of: rootPID) },
            sessionName: sessionName
        )
    }

    /// Inspects sessions concurrently because each observation may invoke several
    /// timeout-bounded tmux subprocesses. Missing backing sessions are retained for
    /// restored rows that have not been attached yet.
    public func observe(_ inputs: [SessionStatusObservationInput]) -> [SessionStatusObservation] {
        guard !inputs.isEmpty else { return [] }

        let supervisor = AgentSupervisor(
            backend: backend,
            processDescendants: processDescendants
        )
        let collector = ObservationCollector()
        DispatchQueue.concurrentPerform(iterations: inputs.count) { index in
            let input = inputs[index]
            guard let result = supervisor.inspect(
                tmuxSessionName: input.tmuxSessionName,
                launchCommand: input.command,
                currentStatus: input.status
            ) else {
                return
            }
            if result.status == .closed && backend.hasSession(named: input.tmuxSessionName) {
                return
            }
            if result.status == .closed && input.isAwaitingAttach {
                return
            }
            collector.append(SessionStatusObservation(
                id: input.id,
                status: result.status,
                tone: result.tone,
                provider: result.provider,
                currentPath: result.currentPath
            ))
        }
        return collector.drain()
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

private final class ObservationCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var observations: [SessionStatusObservation] = []

    func append(_ observation: SessionStatusObservation) {
        lock.lock()
        observations.append(observation)
        lock.unlock()
    }

    func drain() -> [SessionStatusObservation] {
        lock.lock()
        defer { lock.unlock() }
        return observations
    }
}
