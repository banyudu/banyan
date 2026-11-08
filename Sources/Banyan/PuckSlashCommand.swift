import Foundation

/// Composer commands, typed as the whole message, e.g. `/compact`. Any other
/// text that starts with a slash, such as a path, is sent as a message.
enum PuckSlashCommand: String, CaseIterable, Identifiable {
    case compact
    case stop
    case copy
    case status
    case new

    var id: String { rawValue }
    var name: String { "/" + rawValue }

    var summary: String {
        switch self {
        case .compact: "Summarize the conversation to free context"
        case .stop: "Stop the running turn"
        case .copy: "Copy the latest response"
        case .status: "Show the engine, model, workspace, and token usage"
        case .new: "Start a new Puck session like this one"
        }
    }

    /// Commands to offer while the draft is a single slash word.
    static func suggestions(for draft: String) -> [PuckSlashCommand] {
        guard draft.hasPrefix("/"), !draft.contains(where: \.isWhitespace) else { return [] }
        let query = draft.dropFirst().lowercased()
        return allCases.filter { $0.rawValue.hasPrefix(query) }
    }

    static func exact(_ draft: String) -> PuckSlashCommand? {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        return PuckSlashCommand(rawValue: String(trimmed.dropFirst()).lowercased())
    }
}
