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
    /// Parked out of Banyan's supervision and render budget. Orthogonal to
    /// `status`: the tmux session and its agent keep running untouched, so a
    /// suspended row still carries the last observed agent state and resuming
    /// restores it rather than resetting it.
    public let isSuspended: Bool
    /// Persist uncertain or hidden daemon work independently of display status.
    public let agentSlotProviderIdentity: AgentProcessIdentity?
    public let agentSlotPaneIdentity: AgentProcessIdentity?
    public let agentSlotReserved: Bool
    public let agentLaunchQueue: AgentLaunchQueueState?
    public let createdAt: Date
    public let updatedAt: Date
    /// Which runtime owns the session. Rows written before puck sessions
    /// existed are terminal sessions.
    public let backend: SessionBackendKind
    /// The native thread identity and settings of a `.codex` row.
    public let codex: CodexThreadBinding?
    /// The daemon runtime of a `.puck` row; `nil` for terminal sessions.
    public let puck: PuckSessionBinding?

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
        isSuspended: Bool = false,
        agentLaunchQueue: AgentLaunchQueueState? = nil,
        agentSlotReserved: Bool = false,
        agentSlotPaneIdentity: AgentProcessIdentity? = nil,
        agentSlotProviderIdentity: AgentProcessIdentity? = nil,
        createdAt: Date,
        updatedAt: Date,
        backend: SessionBackendKind = .terminal,
        puck: PuckSessionBinding? = nil,
        codex: CodexThreadBinding? = nil
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
        self.isSuspended = isSuspended
        self.agentLaunchQueue = agentLaunchQueue
        self.agentSlotReserved = agentSlotReserved
        self.agentSlotPaneIdentity = agentSlotPaneIdentity
        self.agentSlotProviderIdentity = agentSlotProviderIdentity
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.backend = backend
        self.puck = puck
        self.codex = codex
    }

    public var launchRequest: SessionLaunchRequest {
        SessionLaunchRequest(
            sessionName: tmuxSessionName ?? SessionIdentityPolicy.sessionName(for: id),
            cwd: cwd,
            command: command,
            banyanSessionID: id
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, tmuxSessionName, title, titleURL, titleURLWasAutoDetected
        case reportedTitle, generatedTitle, isTitlePinned, cwd, command
        case status, tone, parentSessionID, agentSessionID, isSuspended, createdAt, updatedAt
        case backend, puck, codex, agentLaunchQueue, agentSlotReserved, agentSlotPaneIdentity, agentSlotProviderIdentity
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
            isSuspended: try container.decodeIfPresent(Bool.self, forKey: .isSuspended) ?? false,
            agentLaunchQueue: try container.decodeIfPresent(AgentLaunchQueueState.self, forKey: .agentLaunchQueue),
            agentSlotReserved: try container.decodeIfPresent(Bool.self, forKey: .agentSlotReserved) ?? false,
            agentSlotPaneIdentity: try container.decodeIfPresent(AgentProcessIdentity.self, forKey: .agentSlotPaneIdentity),
            agentSlotProviderIdentity: try container.decodeIfPresent(AgentProcessIdentity.self, forKey: .agentSlotProviderIdentity),
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            updatedAt: try container.decode(Date.self, forKey: .updatedAt),
            backend: try container.decodeIfPresent(SessionBackendKind.self, forKey: .backend) ?? .terminal,
            puck: try container.decodeIfPresent(PuckSessionBinding.self, forKey: .puck),
            codex: try container.decodeIfPresent(CodexThreadBinding.self, forKey: .codex)
        )
    }

    public func updating(
        status: SessionStatus? = nil,
        tone: SessionTone? = nil,
        title: String? = nil,
        isSuspended: Bool? = nil,
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
            isSuspended: isSuspended ?? self.isSuspended,
            agentLaunchQueue: agentLaunchQueue,
            agentSlotReserved: agentSlotReserved,
            agentSlotPaneIdentity: agentSlotPaneIdentity,
            agentSlotProviderIdentity: agentSlotProviderIdentity,
            createdAt: createdAt,
            updatedAt: updatedAt,
            backend: backend,
            puck: puck,
            codex: codex
        )
    }
}
