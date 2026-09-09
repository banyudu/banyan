import Foundation

/// The fields resume matching actually reads off a recorded conversation.
///
/// Picking a resume target never looks at titles or transcript bodies — only at
/// which agent wrote the conversation, where it ran, and when. Keeping that
/// surface explicit lets the matcher run against candidates discovered cheaply
/// (`AgentResumeCandidate`) as well as fully imported ones
/// (`ImportedAgentSession`).
public protocol AgentResumeMatchable {
    var provider: CodingAgentProvider { get }
    var cwd: String { get }
    var createdAt: Date { get }
    var updatedAt: Date { get }
}

/// A resumable conversation discovered without parsing its transcript body.
public struct AgentResumeCandidate: Sendable, Equatable, AgentResumeMatchable {
    public let provider: CodingAgentProvider
    public let sourceID: String
    public let cwd: String
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        provider: CodingAgentProvider,
        sourceID: String,
        cwd: String,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.provider = provider
        self.sourceID = sourceID
        self.cwd = cwd
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(imported: ImportedAgentSession) {
        self.init(
            provider: imported.provider,
            sourceID: imported.sourceID,
            cwd: imported.cwd,
            createdAt: imported.createdAt,
            updatedAt: imported.updatedAt
        )
    }
}

extension ImportedAgentSession: AgentResumeMatchable {}
