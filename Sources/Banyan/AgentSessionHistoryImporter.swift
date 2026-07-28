import BanyanCore
import Foundation

/// Compatibility facade for the macOS frontend while history parsing lives in
/// BanyanCore.
enum AgentSessionHistoryImporter {
    static func load(
        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory()),
        maxPerProvider: Int = 10,
        fileManager: FileManager = .default
    ) -> [ImportedAgentSession] {
        BanyanCore.AgentSessionHistoryImporter.load(
            homeDirectory: homeDirectory,
            maxPerProvider: maxPerProvider,
            fileManager: fileManager
        )
    }

    static func transcriptPreview(
        from url: URL,
        provider: CodingAgentProvider,
        maxMessages: Int = 40
    ) -> String {
        BanyanCore.AgentSessionHistoryImporter.transcriptPreview(
            from: url,
            provider: provider,
            maxMessages: maxMessages
        )
    }

    static func sourceID(fromImportedSessionID id: String, provider: CodingAgentProvider) -> String? {
        BanyanCore.AgentSessionHistory.sourceID(fromImportedSessionID: id, provider: provider)
    }

    static func resumeCommand(
        provider: CodingAgentProvider,
        sourceID: String,
        cwd: String,
        prompt: String? = nil
    ) -> String? {
        BanyanCore.AgentSessionHistory.resumeCommand(
            provider: provider,
            sourceID: sourceID,
            cwd: cwd,
            prompt: prompt
        )
    }
}
