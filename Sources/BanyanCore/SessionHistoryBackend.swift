import Foundation

/// History operations required when turning an imported conversation into a
/// live session. Frontends can provide a platform-specific history store while
/// keeping session creation and tmux lifecycle behavior shared.
public protocol SessionHistoryBackend: Sendable {
    func load(maxPerProvider limit: Int) -> [ImportedAgentSession]
    func sourceID(fromImportedSessionID id: String, provider: CodingAgentProvider) -> String?
    func resumeCommand(
        provider: CodingAgentProvider,
        sourceID: String,
        cwd: String,
        prompt: String?
    ) -> String?
    func prepareTrimmedTranscript(
        provider: CodingAgentProvider,
        sourceID: String,
        cwd: String,
        transcriptURL: URL?
    ) -> String?
}

public struct DefaultSessionHistoryBackend: Sendable, SessionHistoryBackend {
    public init() {}

    public func load(maxPerProvider limit: Int) -> [ImportedAgentSession] {
        AgentSessionHistoryImporter.load(maxPerProvider: limit)
    }

    public func sourceID(
        fromImportedSessionID id: String,
        provider: CodingAgentProvider
    ) -> String? {
        AgentSessionHistory.sourceID(fromImportedSessionID: id, provider: provider)
    }

    public func resumeCommand(
        provider: CodingAgentProvider,
        sourceID: String,
        cwd: String,
        prompt: String? = nil
    ) -> String? {
        AgentSessionHistory.resumeCommand(
            provider: provider,
            sourceID: sourceID,
            cwd: cwd,
            prompt: prompt
        )
    }

    public func prepareTrimmedTranscript(
        provider: CodingAgentProvider,
        sourceID: String,
        cwd: String,
        transcriptURL: URL?
    ) -> String? {
        TranscriptResumePreparer.prepare(
            provider: provider,
            sourceID: sourceID,
            cwd: cwd,
            transcriptURL: transcriptURL
        )?.newSourceID
    }
}
