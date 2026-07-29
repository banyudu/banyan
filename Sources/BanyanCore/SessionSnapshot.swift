import Foundation

public struct SessionSnapshot: Codable, Equatable, Sendable {
    public let id: String
    public let tmuxSessionName: String?
    public let title: String
    public let titleURL: String?
    /// Whether `titleURL` came from the cwd/branch rather than an explicit choice.
    public let titleURLWasAutoDetected: Bool
    public let reportedTitle: String?
    public let generatedTitle: String?
    public let isTitlePinned: Bool
    public let cwd: String
    public let command: String
    public let status: SessionStatus
    public let tone: SessionTone
    public let parentSessionID: String?
    public let agentSessionID: String?
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: String,
        tmuxSessionName: String?,
        title: String,
        titleURL: String? = nil,
        titleURLWasAutoDetected: Bool = true,
        reportedTitle: String?,
        generatedTitle: String? = nil,
        isTitlePinned: Bool = false,
        cwd: String,
        command: String,
        status: SessionStatus,
        tone: SessionTone,
        parentSessionID: String? = nil,
        agentSessionID: String? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.tmuxSessionName = tmuxSessionName
        self.title = title
        self.titleURL = titleURL
        self.titleURLWasAutoDetected = titleURLWasAutoDetected
        self.reportedTitle = reportedTitle
        self.generatedTitle = generatedTitle
        self.isTitlePinned = isTitlePinned
        self.cwd = cwd
        self.command = command
        self.status = status
        self.tone = tone
        self.parentSessionID = parentSessionID
        self.agentSessionID = agentSessionID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var launchRequest: SessionLaunchRequest {
        SessionLaunchRequest(
            sessionName: tmuxSessionName ?? SessionIdentityPolicy.sessionName(for: id),
            cwd: cwd,
            command: command
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, tmuxSessionName, title, titleURL, titleURLWasAutoDetected
        case reportedTitle, generatedTitle, isTitlePinned, cwd, command
        case status, tone, parentSessionID, agentSessionID, createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            tmuxSessionName: try container.decodeIfPresent(String.self, forKey: .tmuxSessionName),
            title: try container.decode(String.self, forKey: .title),
            titleURL: try container.decodeIfPresent(String.self, forKey: .titleURL),
            titleURLWasAutoDetected: try container.decodeIfPresent(Bool.self, forKey: .titleURLWasAutoDetected) ?? true,
            reportedTitle: try container.decodeIfPresent(String.self, forKey: .reportedTitle),
            generatedTitle: try container.decodeIfPresent(String.self, forKey: .generatedTitle),
            isTitlePinned: try container.decodeIfPresent(Bool.self, forKey: .isTitlePinned) ?? false,
            cwd: try container.decode(String.self, forKey: .cwd),
            command: try container.decode(String.self, forKey: .command),
            status: try container.decode(SessionStatus.self, forKey: .status),
            tone: try container.decode(SessionTone.self, forKey: .tone),
            parentSessionID: try container.decodeIfPresent(String.self, forKey: .parentSessionID),
            agentSessionID: try container.decodeIfPresent(String.self, forKey: .agentSessionID),
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            updatedAt: try container.decode(Date.self, forKey: .updatedAt)
        )
    }

    public func updating(
        status: SessionStatus? = nil,
        tone: SessionTone? = nil,
        title: String? = nil,
        updatedAt: Date = Date()
    ) -> SessionSnapshot {
        SessionSnapshot(
            id: id,
            tmuxSessionName: tmuxSessionName,
            title: title ?? self.title,
            titleURL: titleURL,
            titleURLWasAutoDetected: titleURLWasAutoDetected,
            reportedTitle: reportedTitle,
            generatedTitle: generatedTitle,
            isTitlePinned: isTitlePinned,
            cwd: cwd,
            command: command,
            status: status ?? self.status,
            tone: tone ?? self.tone,
            parentSessionID: parentSessionID,
            agentSessionID: agentSessionID,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}
