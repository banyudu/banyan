import Foundation

/// A transcript source resolved from Banyan's session identity. It deliberately
/// carries only immutable data that can cross to a utility-priority reader.
public struct SessionCostTranscriptSource: Sendable, Equatable {
    public let provider: SessionCostProvider
    public let transcriptURL: URL
    public let sessionKey: String

    public init(
        provider: SessionCostProvider,
        transcriptURL: URL,
        sessionKey: String
    ) {
        self.provider = provider
        self.transcriptURL = transcriptURL
        self.sessionKey = sessionKey
    }
}

public enum SessionCostTranscriptResolver {
    /// Resolves only an exact provider/session-ID match in the already-imported
    /// history. No directory discovery belongs on the hover path.
    public static func source(
        provider: CodingAgentProvider?,
        agentSessionID: String?,
        importedHistory: [ImportedAgentSession]
    ) -> SessionCostTranscriptSource? {
        guard let provider, [.codex, .claude].contains(provider),
              let agentSessionID,
              !agentSessionID.isEmpty
        else {
            return nil
        }

        let matches = importedHistory.filter {
            $0.provider == provider && $0.sourceID == agentSessionID
        }
        guard matches.count == 1, let match = matches.first else { return nil }
        return SessionCostTranscriptSource(
            provider: provider == .codex ? .codex : .claude,
            transcriptURL: match.transcriptURL,
            sessionKey: "\(provider.rawValue):\(agentSessionID)"
        )
    }

    public static func importedHistorySource(
        provider: CodingAgentProvider?,
        transcriptURL: URL?
    ) -> SessionCostTranscriptSource? {
        guard let provider, [.codex, .claude].contains(provider),
              let transcriptURL
        else {
            return nil
        }
        return SessionCostTranscriptSource(
            provider: provider == .codex ? .codex : .claude,
            transcriptURL: transcriptURL,
            sessionKey: "\(provider.rawValue):\(transcriptURL.standardizedFileURL.path)"
        )
    }
}
