import Foundation

struct SessionShortcutConfiguration: Equatable {
    var visibleRowShortcuts = true

    static func load(homeDirectory: URL) -> (configuration: Self, diagnostic: String?) {
        let url = SessionLaunchProfileLoader.configURL(homeDirectory: homeDirectory)
        guard FileManager.default.fileExists(atPath: url.path) else { return (Self(), nil) }
        do {
            return (try parse(String(contentsOf: url, encoding: .utf8)), nil)
        } catch {
            return (Self(), "Could not load session shortcuts from \(url.path): \(error.localizedDescription). Using visible-row shortcuts.")
        }
    }

    /// Read only our top-level boolean; launch and palette sections are owned
    /// by their respective loaders. An omitted key keeps rolling enabled.
    static func parse(_ yaml: String) throws -> Self {
        var configuration = Self()
        var found = false
        for rawLine in yaml.split(whereSeparator: \.isNewline) {
            guard rawLine.first?.isWhitespace == false else { continue }
            let line = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let field = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard field.first?.trimmingCharacters(in: .whitespaces) == "visible_row_shortcuts" else { continue }
            guard !found, field.count == 2 else { throw ConfigurationError.invalidBoolean }
            found = true
            switch field[1].trimmingCharacters(in: .whitespaces).lowercased() {
            case "true": configuration.visibleRowShortcuts = true
            case "false": configuration.visibleRowShortcuts = false
            default: throw ConfigurationError.invalidBoolean
            }
        }
        return configuration
    }

    private enum ConfigurationError: LocalizedError {
        case invalidBoolean

        var errorDescription: String? {
            "visible_row_shortcuts must appear once with a true or false value"
        }
    }
}
