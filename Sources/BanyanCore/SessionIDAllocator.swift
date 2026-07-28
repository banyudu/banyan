import Foundation

/// Allocates IDs for newly created persisted sessions.
public protocol SessionIDAllocator: Sendable {
    func allocate(prefix: String) -> String
}

/// Preserves Banyan's existing ID format while keeping collision checks out of
/// frontend-independent session actions.
public struct UniqueSessionIDAllocator: Sendable, SessionIDAllocator {
    private let persistence: any SessionPersistenceBackend
    private let tmux: any TmuxSessionLookupBackend

    public init(
        persistence: any SessionPersistenceBackend,
        tmux: any TmuxSessionLookupBackend
    ) {
        self.persistence = persistence
        self.tmux = tmux
    }

    public func allocate(prefix: String) -> String {
        let existingIDs = Set(persistence.load().map(\.id))
        var candidate = prefix
        var suffix = 2
        while existingIDs.contains(candidate)
                || tmux.hasSession(named: SessionIdentityPolicy.sessionName(for: candidate)) {
            candidate = "\(prefix)-\(suffix)"
            suffix += 1
        }
        return candidate
    }
}
