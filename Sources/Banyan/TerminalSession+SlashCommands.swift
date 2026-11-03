import Foundation

extension TerminalSession {
    var acceptsTerminalSlashCommand: Bool {
        TerminalSlashCommandPolicy.canHandle(
            provider: detectedAgentProvider,
            isImportedHistory: isImportedHistory,
            status: status
        )
    }
}
