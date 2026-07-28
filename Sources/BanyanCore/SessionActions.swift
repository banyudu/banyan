import Foundation

public protocol SessionListActions: Sendable {
    func createShellSession(cwd: String) throws -> String
    func resumeHistory(_ item: ImportedAgentSession, trimmed: Bool) throws -> Bool
    func recover(_ session: SessionSnapshot) throws
    func close(_ session: SessionSnapshot)
    func remove(_ session: SessionSnapshot)
}

/// Shared session lifecycle actions used by terminal frontends.
public struct SessionActions: Sendable, SessionListActions {
    private let idAllocator: any SessionIDAllocator
    private let catalog: any SessionCatalogBackend
    private let history: any SessionHistoryBackend

    public init(
        idAllocator: any SessionIDAllocator,
        catalog: any SessionCatalogBackend,
        history: any SessionHistoryBackend
    ) {
        self.idAllocator = idAllocator
        self.catalog = catalog
        self.history = history
    }

    public func createShellSession(cwd: String) throws -> String {
        let id = idAllocator.allocate(prefix: "tui-shell")
        let now = Date()
        let snapshot = SessionSnapshot(
            id: id,
            tmuxSessionName: SessionIdentityPolicy.sessionName(for: id),
            title: "Shell",
            reportedTitle: nil,
            cwd: cwd,
            command: "",
            status: .running,
            tone: .blue,
            createdAt: now,
            updatedAt: now
        )
        try catalog.create(snapshot: snapshot)
        return id
    }

    /// Creates a resumed session and returns whether a trimmed transcript was used.
    public func resumeHistory(_ item: ImportedAgentSession, trimmed: Bool) throws -> Bool {
        guard let sourceID = history.sourceID(
            fromImportedSessionID: item.id,
            provider: item.provider
        ) else {
            throw SessionActionError.unresumable(item.title)
        }

        let preparedSourceID = trimmed ? history.prepareTrimmedTranscript(
            provider: item.provider,
            sourceID: sourceID,
            cwd: item.cwd,
            transcriptURL: item.transcriptURL
        ) : nil
        let resumeSourceID = preparedSourceID ?? sourceID
        guard let command = history.resumeCommand(
            provider: item.provider,
            sourceID: resumeSourceID,
            cwd: item.cwd,
            prompt: nil
        ) else {
            throw SessionActionError.unresumable(item.title)
        }

        let id = idAllocator.allocate(prefix: "\(item.provider.rawValue)-\(resumeSourceID.prefix(8))")
        let now = Date()
        let snapshot = SessionSnapshot(
            id: id,
            tmuxSessionName: SessionIdentityPolicy.sessionName(for: id),
            title: item.title,
            reportedTitle: item.title,
            cwd: item.cwd,
            command: command,
            status: .running,
            tone: .blue,
            createdAt: now,
            updatedAt: now
        )
        try catalog.create(snapshot: snapshot)
        return preparedSourceID != nil
    }

    public func recover(_ session: SessionSnapshot) throws {
        try catalog.recover(snapshot: session)
    }

    public func close(_ session: SessionSnapshot) {
        catalog.close(snapshot: session)
    }

    public func remove(_ session: SessionSnapshot) {
        catalog.remove(snapshot: session)
    }

    public func sessionName(for session: SessionSnapshot) -> String {
        session.launchRequest.sessionName
    }

}

public enum SessionActionError: LocalizedError {
    case unresumable(String)

    public var errorDescription: String? {
        switch self {
        case .unresumable(let title):
            return "Unable to resume \(title)"
        }
    }
}
