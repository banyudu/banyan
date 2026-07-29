import Foundation

/// Pure naming rules for sessions created by resuming imported agent history.
public enum SessionResumePolicy {
    public struct Plan: Sendable, Equatable {
        public let sourceID: String
        public let command: String
        public let usedTrimmedTranscript: Bool

        public init(sourceID: String, command: String, usedTrimmedTranscript: Bool) {
            self.sourceID = sourceID
            self.command = command
            self.usedTrimmedTranscript = usedTrimmedTranscript
        }
    }

    /// Prepares the source ID and provider command used to launch a resumed
    /// conversation. A nil result means the caller should use its normal
    /// non-resume fallback.
    public static func plan(
        provider: CodingAgentProvider,
        sourceID: String,
        cwd: String,
        prompt: String?,
        transcriptURL: URL?,
        trimmed: Bool,
        history: any SessionHistoryBackend
    ) -> Plan? {
        let preparedSourceID = trimmed ? history.prepareTrimmedTranscript(
            provider: provider,
            sourceID: sourceID,
            cwd: cwd,
            transcriptURL: transcriptURL
        ) : nil
        let resumeSourceID = preparedSourceID ?? sourceID
        guard let command = history.resumeCommand(
            provider: provider,
            sourceID: resumeSourceID,
            cwd: cwd,
            prompt: prompt
        ) else {
            return nil
        }
        return Plan(
            sourceID: resumeSourceID,
            command: command,
            usedTrimmedTranscript: preparedSourceID != nil
        )
    }

    /// Returns the stable prefix used before the session ID allocator adds a
    /// suffix when the prefix is already occupied.
    public static func sessionIDPrefix(
        provider: CodingAgentProvider,
        sourceID: String
    ) -> String {
        "\(provider.rawValue)-\(sourceID.prefix(8))"
    }
}
