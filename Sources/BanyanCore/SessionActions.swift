import Foundation

/// Shared session lifecycle actions used by terminal frontends.
public struct SessionActions: Sendable {
    private let database: SessionDatabase
    private let tmux: TmuxBackend
    private let catalog: SessionCatalog

    public init(
        database: SessionDatabase,
        tmux: TmuxBackend,
        catalog: SessionCatalog
    ) {
        self.database = database
        self.tmux = tmux
        self.catalog = catalog
    }

    public func createShellSession(
        cwd: String = FileManager.default.currentDirectoryPath
    ) throws -> String {
        let id = uniqueSessionID()
        let now = Date()
        let snapshot = SessionSnapshot(
            id: id,
            tmuxSessionName: TmuxBackend.sessionName(for: id),
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
        guard let sourceID = AgentSessionHistory.sourceID(
            fromImportedSessionID: item.id,
            provider: item.provider
        ) else {
            throw SessionActionError.unresumable(item.title)
        }

        let prepared = trimmed ? TranscriptResumePreparer.prepare(
            provider: item.provider,
            sourceID: sourceID,
            cwd: item.cwd,
            transcriptURL: item.transcriptURL
        ) : nil
        let resumeSourceID = prepared?.newSourceID ?? sourceID
        guard let command = AgentSessionHistory.resumeCommand(
            provider: item.provider,
            sourceID: resumeSourceID,
            cwd: item.cwd
        ) else {
            throw SessionActionError.unresumable(item.title)
        }

        let id = uniqueSessionID(prefix: "\(item.provider.rawValue)-\(resumeSourceID.prefix(8))")
        let now = Date()
        let snapshot = SessionSnapshot(
            id: id,
            tmuxSessionName: TmuxBackend.sessionName(for: id),
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
        return prepared != nil
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

    private func uniqueSessionID(prefix: String = "tui-shell") -> String {
        let existingIDs = Set(database.load().map(\.id))
        var candidate = prefix
        var suffix = 2
        while existingIDs.contains(candidate) || tmux.hasSession(named: TmuxBackend.sessionName(for: candidate)) {
            candidate = "\(prefix)-\(suffix)"
            suffix += 1
        }
        return candidate
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
