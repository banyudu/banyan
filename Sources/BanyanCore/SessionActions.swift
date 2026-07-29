import Foundation

public protocol SessionListActions: Sendable {
    func createShellSession(cwd: String) throws -> String
    func createSession(title: String?, cwd: String, command: String) throws -> String
    func resumeHistory(_ item: ImportedAgentSession, trimmed: Bool) throws -> Bool
    func recover(_ session: SessionSnapshot) throws
    func rename(_ session: SessionSnapshot, title: String)
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
        try createSession(title: "Shell", cwd: cwd, command: "", idPrefix: "tui-shell")
    }

    public func createSession(title: String?, cwd: String, command: String) throws -> String {
        try createSession(title: title, cwd: cwd, command: command, idPrefix: nil)
    }

    private func createSession(
        title: String?,
        cwd: String,
        command: String,
        idPrefix: String?
    ) throws -> String {
        let normalizedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionTitle = normalizedTitle?.isEmpty == false ? normalizedTitle! : "Shell"
        let prefix = idPrefix ?? SessionIdentityPolicy.sanitizedID(sessionTitle)
        let id = idAllocator.allocate(prefix: prefix.isEmpty ? "tui-session" : prefix)
        let now = Date()
        let snapshot = SessionSnapshot(
            id: id,
            tmuxSessionName: SessionIdentityPolicy.sessionName(for: id),
            title: sessionTitle,
            reportedTitle: nil,
            cwd: cwd,
            command: command,
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

        guard let plan = SessionResumePolicy.plan(
            provider: item.provider,
            sourceID: sourceID,
            cwd: item.cwd,
            prompt: nil,
            transcriptURL: item.transcriptURL,
            trimmed: trimmed,
            history: history
        ) else {
            throw SessionActionError.unresumable(item.title)
        }

        let id = idAllocator.allocate(
            prefix: SessionResumePolicy.sessionIDPrefix(
                provider: item.provider,
                sourceID: plan.sourceID
            )
        )
        let now = Date()
        let snapshot = SessionSnapshot(
            id: id,
            tmuxSessionName: SessionIdentityPolicy.sessionName(for: id),
            title: item.title,
            reportedTitle: item.title,
            cwd: item.cwd,
            command: plan.command,
            status: .running,
            tone: .blue,
            createdAt: now,
            updatedAt: now
        )
        try catalog.create(snapshot: snapshot)
        return plan.usedTrimmedTranscript
    }

    public func recover(_ session: SessionSnapshot) throws {
        try catalog.recover(snapshot: session)
    }

    public func rename(_ session: SessionSnapshot, title: String) {
        catalog.rename(snapshot: session, title: title)
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
