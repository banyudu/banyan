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
    func transcriptPreview(
        from url: URL,
        provider: CodingAgentProvider,
        maxMessages: Int
    ) -> String
}

public extension SessionHistoryBackend {
    func transcriptPreview(
        from url: URL,
        provider: CodingAgentProvider,
        maxMessages: Int = 40
    ) -> String {
        "No readable transcript preview is available for this history file."
    }
}

public struct DefaultSessionHistoryBackend: Sendable, SessionHistoryBackend {
    private let homeDirectory: URL

    public init(homeDirectory: URL) {
        self.homeDirectory = homeDirectory
    }

    public func load(maxPerProvider limit: Int) -> [ImportedAgentSession] {
        AgentSessionHistoryImporter.load(
            homeDirectory: homeDirectory,
            maxPerProvider: limit
        )
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
            transcriptURL: transcriptURL,
            home: homeDirectory
        )?.newSourceID
    }

    public func transcriptPreview(
        from url: URL,
        provider: CodingAgentProvider,
        maxMessages: Int = 40
    ) -> String {
        AgentSessionHistoryImporter.transcriptPreview(
            from: url,
            provider: provider,
            maxMessages: maxMessages
        )
    }
}
