import Foundation

/// A coding-agent conversation discovered from the provider's local history.
public struct ImportedAgentSession: Identifiable, Equatable, Sendable {
    public let id: String
    public let provider: CodingAgentProvider
    public let sourceID: String
    public let title: String
    /// Title of the conversation's current segment after the latest reset.
    public let segmentPromptTitle: String?
    /// Whether the latest reset has not yet received a new prompt.
    public let segmentWasCleared: Bool
    /// Title the coding agent generated for this conversation itself, when it
    /// publishes one. Outranks any title Banyan derives from the first prompt.
    public let agentGeneratedTitle: String?
    public let cwd: String
    public let transcriptURL: URL
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: String,
        provider: CodingAgentProvider,
        sourceID: String,
        title: String,
        segmentPromptTitle: String? = nil,
        segmentWasCleared: Bool = false,
        agentGeneratedTitle: String? = nil,
        cwd: String,
        transcriptURL: URL,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.provider = provider
        self.sourceID = sourceID
        self.title = title
        self.segmentPromptTitle = segmentPromptTitle
        self.segmentWasCleared = segmentWasCleared
        self.agentGeneratedTitle = agentGeneratedTitle
        self.cwd = cwd
        self.transcriptURL = transcriptURL
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
