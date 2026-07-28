import BanyanCore
import Foundation

struct TUISessionActions {
    let database: SessionDatabase
    let tmux: TmuxBackend
    let catalog: SessionCatalog

    func createShellSession() throws -> String {
        let id = uniqueSessionID()
        let cwd = FileManager.default.currentDirectoryPath
        let request = SessionLaunchRequest(
            sessionName: TmuxBackend.sessionName(for: id),
            cwd: cwd,
            command: ""
        )
        let now = Date()
        let snapshot = SessionSnapshot(
            id: id,
            tmuxSessionName: request.sessionName,
            title: "Shell",
            reportedTitle: nil,
            cwd: cwd,
            command: "",
            status: .running,
            tone: .blue,
            createdAt: now,
            updatedAt: now
        )
        try catalog.create(snapshot: snapshot, launchRequest: request)
        return id
    }

    /// Creates a resumed session and returns whether a trimmed transcript was used.
    func resumeHistory(_ item: ImportedAgentSession, trimmed: Bool) throws -> Bool {
        guard let sourceID = AgentSessionHistory.sourceID(
            fromImportedSessionID: item.id,
            provider: item.provider
        ) else {
            throw TUISessionActionError.unresumable(item.title)
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
            throw TUISessionActionError.unresumable(item.title)
        }

        let id = uniqueSessionID(prefix: "\(item.provider.rawValue)-\(resumeSourceID.prefix(8))")
        let now = Date()
        let request = SessionLaunchRequest(
            sessionName: TmuxBackend.sessionName(for: id),
            cwd: item.cwd,
            command: command
        )
        let snapshot = SessionSnapshot(
            id: id,
            tmuxSessionName: request.sessionName,
            title: item.title,
            reportedTitle: item.title,
            cwd: item.cwd,
            command: command,
            status: .running,
            tone: .blue,
            createdAt: now,
            updatedAt: now
        )
        try catalog.create(snapshot: snapshot, launchRequest: request)
        return prepared != nil
    }

    func recover(_ session: SessionSnapshot) throws {
        let request = SessionLaunchRequest(
            sessionName: sessionName(for: session),
            cwd: session.cwd,
            command: session.command
        )
        try catalog.recover(snapshot: session, launchRequest: request)
    }

    func close(_ session: SessionSnapshot) {
        catalog.close(snapshot: session)
    }

    func remove(_ session: SessionSnapshot) {
        catalog.remove(snapshot: session)
    }

    func sessionName(for session: SessionSnapshot) -> String {
        session.tmuxSessionName ?? TmuxBackend.sessionName(for: session.id)
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

enum TUISessionActionError: LocalizedError {
    case unresumable(String)

    var errorDescription: String? {
        switch self {
        case .unresumable(let title):
            return "Unable to resume \(title)"
        }
    }
}
