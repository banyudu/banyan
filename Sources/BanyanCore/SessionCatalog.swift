import Foundation

/// Coordinates persisted session snapshots with their tmux-backed lifecycle.
/// Frontends remain responsible for presentation and selection state.
public struct SessionCatalog: Sendable {
    private let persistence: any SessionPersistenceBackend
    private let runtime: SessionRuntimeCoordinator

    public init(
        persistence: any SessionPersistenceBackend,
        runtime: SessionRuntimeCoordinator
    ) {
        self.persistence = persistence
        self.runtime = runtime
    }

    public func create(snapshot: SessionSnapshot) throws {
        try runtime.ensureBackingSession(snapshot.launchRequest)
        persistence.save(persistence.load() + [snapshot])
    }

    public func recover(snapshot: SessionSnapshot) throws {
        try runtime.ensureBackingSession(snapshot.launchRequest)
    }

    public func close(snapshot: SessionSnapshot) {
        runtime.removeBackingSession(named: sessionName(for: snapshot))
        update(snapshotID: snapshot.id) { $0.updating(status: .closed) }
    }

    public func remove(snapshot: SessionSnapshot) {
        runtime.removeBackingSession(named: sessionName(for: snapshot))
        persistence.save(persistence.load().filter { $0.id != snapshot.id })
    }

    private func update(
        snapshotID: String,
        _ transform: (SessionSnapshot) -> SessionSnapshot
    ) {
        persistence.save(persistence.load().map { snapshot in
            guard snapshot.id == snapshotID else { return snapshot }
            return transform(snapshot)
        })
    }

    private func sessionName(for snapshot: SessionSnapshot) -> String {
        snapshot.tmuxSessionName ?? TmuxBackend.sessionName(for: snapshot.id)
    }
}
