import BanyanCore
import Foundation

/// A user-defined command palette entry.
///
/// Configured in `~/.banyan/config.yml` under `palette_commands:` — the same
/// file that already holds `session_launches:`. Keeping personal workflows
/// (e.g. `~/bin/workit`, `~/bin/verify-linear`) in config preserves the
/// repo's shareable-content rule: no personal paths or binaries are baked in.
struct PaletteCommand: Identifiable, Hashable, Codable {
    enum RunMode: String, Codable {
        case session
        case background
    }

    enum When: String, Codable {
        case always
        case issue
        case linear
        case github
    }

    let id: String
    let title: String
    let command: String
    let run: RunMode
    let when: When

    init(id: String, title: String, command: String, run: RunMode = .session, when: When = .always) {
        self.id = id
        self.title = title
        self.command = command
        self.run = run
        self.when = when
    }

    /// Expand `{{target}}` (plus `{{id}}` / `{{issue}}` aliases) and `{{query}}`.
    func expandedTitle(target: String?, query: String?) -> String {
        Self.expand(template: title, target: target, query: query)
    }

    func expandedCommand(target: String?, query: String?) -> String {
        Self.expand(template: command, target: target, query: query)
    }

    static func expand(template: String, target: String?, query: String?) -> String {
        var result = template
        let targetValue = target ?? ""
        for placeholder in ["{{target}}", "{{id}}", "{{issue}}"] {
            result = result.replacingOccurrences(of: placeholder, with: targetValue)
        }
        if let query {
            result = result.replacingOccurrences(of: "{{query}}", with: query)
        }
        return result
    }

    var needsTarget: Bool {
        title.contains("{{target}}") || title.contains("{{id}}") || title.contains("{{issue}}")
            || command.contains("{{target}}") || command.contains("{{id}}") || command.contains("{{issue}}")
    }
}

/// The issue target a palette query resolves to, if any.
enum PaletteCommandTarget: Equatable {
    case linear(String)
    case github(String)

    var value: String {
        switch self {
        case .linear(let id): return id
        case .github(let ref): return ref
        }
    }

    var isLinear: Bool {
        if case .linear = self { return true }
        return false
    }

    var isGitHub: Bool {
        if case .github = self { return true }
        return false
    }

    /// Linear IDs first (`ENG-123`, `open ENG-123`), then GitHub issue URLs.
    static func detect(in query: String) -> PaletteCommandTarget? {
        if let linearID = LinearIssueReference.issueID(in: query) {
            return .linear(linearID)
        }
        if let ref = GitHubIssueReference.detect(in: query) {
            return .github(ref.url)
        }
        return nil
    }
}

extension PaletteCommand {
    /// Whether this command should be promoted to the top of the palette when
    /// `target` was detected in the query.
    func matches(target: PaletteCommandTarget?) -> Bool {
        guard let target else { return false }
        switch when {
        case .always, .issue:
            return true
        case .linear:
            return target.isLinear
        case .github:
            return target.isGitHub
        }
    }
}

/// Minimal strict YAML reader for the `palette_commands:` section, mirroring
/// `SessionLaunchProfileLoader` so commands stay opaque strings without a
/// general-purpose parser dependency.
enum PaletteCommandLoader {
    static func configURL(homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent(".banyan/config.yml")
    }

    /// Load from the standard config path. A missing file or a file without
    /// `palette_commands:` yields no commands and no diagnostic — the section
    /// is optional, unlike `session_launches:` handling for profiles.
    static func load(
        homeDirectory: URL,
        fileManager: FileManager = .default
    ) -> PaletteCommandLoadResult {
        let url = configURL(homeDirectory: homeDirectory)
        guard fileManager.fileExists(atPath: url.path) else {
            return PaletteCommandLoadResult(commands: [], diagnostic: nil)
        }
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return PaletteCommandLoadResult(commands: [], diagnostic: nil)
        }
        if !contents.contains("palette_commands:") {
            return PaletteCommandLoadResult(commands: [], diagnostic: nil)
        }
        do {
            return PaletteCommandLoadResult(commands: try parse(contents), diagnostic: nil)
        } catch {
            return PaletteCommandLoadResult(
                commands: [],
                diagnostic: "Could not load palette commands from \(url.path): \(error.localizedDescription). Ignoring custom commands."
            )
        }
    }

    static func parse(_ yaml: String) throws -> [PaletteCommand] {
        var fields: [[String: String]] = []
        var current: [String: String]?
        var foundSection = false
        var inSection = false

        for (offset, rawLine) in yaml.split(whereSeparator: \.isNewline).enumerated() {
            let lineNumber = offset + 1
            let line = stripComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            // Top-level keys other than palette_commands: end our section and
            // are otherwise ignored so session_launches: can coexist.
            if !line.hasPrefix("-"), !line.hasPrefix(" "), line.hasSuffix(":") {
                if line == "palette_commands:" {
                    guard !foundSection, current == nil else { throw ParseError(lineNumber, "duplicate palette_commands section") }
                    foundSection = true
                    inSection = true
                    continue
                }
                inSection = false
                continue
            }
            guard inSection else { continue }
            if line.hasPrefix("-") {
                if let current { fields.append(current) }
                let remainder = line.dropFirst().trimmingCharacters(in: .whitespaces)
                guard !remainder.isEmpty else {
                    current = [:]
                    continue
                }
                current = try parseField(String(remainder), lineNumber: lineNumber)
            } else {
                guard var item = current else { throw ParseError(lineNumber, "expected a command entry") }
                let field = try parseField(line, lineNumber: lineNumber)
                for (key, value) in field {
                    guard item[key] == nil else { throw ParseError(lineNumber, "duplicate \(key) field") }
                    item[key] = value
                }
                current = item
            }
        }
        if let current { fields.append(current) }
        guard foundSection else { throw ParseError(1, "missing palette_commands section") }

        var ids = Set<String>()
        return try fields.enumerated().map { index, item in
            guard let id = item["id"]?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty,
                  let title = item["title"]?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
                  let command = item["command"]
            else { throw ParseError(index + 1, "each command requires non-empty id, title, and command") }
            guard ids.insert(id).inserted else { throw ParseError(index + 1, "duplicate command id '\(id)'") }
            let run: PaletteCommand.RunMode
            if let raw = item["run"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty {
                guard let parsed = PaletteCommand.RunMode(rawValue: raw) else {
                    throw ParseError(index + 1, "unknown run '\(raw)' (expected session or background)")
                }
                run = parsed
            } else {
                run = .session
            }
            let when: PaletteCommand.When
            if let raw = item["when"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty {
                guard let parsed = PaletteCommand.When(rawValue: raw) else {
                    throw ParseError(index + 1, "unknown when '\(raw)' (expected always, issue, linear, or github)")
                }
                when = parsed
            } else {
                when = .always
            }
            return PaletteCommand(id: id, title: title, command: command, run: run, when: when)
        }
    }

    private static func parseField(_ line: String, lineNumber: Int) throws -> [String: String] {
        guard let separator = line.firstIndex(of: ":") else { throw ParseError(lineNumber, "expected key: value") }
        let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
        guard ["id", "title", "command", "run", "when"].contains(key) else { throw ParseError(lineNumber, "unknown field '\(key)'") }
        let value = try scalar(String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces), lineNumber: lineNumber)
        return [key: value]
    }

    private static func scalar(_ value: String, lineNumber: Int) throws -> String {
        guard !value.isEmpty else { return "" }
        if value.hasPrefix("\"") {
            guard value.count >= 2, value.hasSuffix("\"") else { throw ParseError(lineNumber, "unterminated quoted value") }
            guard let data = value.data(using: .utf8),
                  let decoded = try JSONSerialization.jsonObject(
                    with: data,
                    options: [.fragmentsAllowed]
                  ) as? String
            else { throw ParseError(lineNumber, "invalid quoted value") }
            return decoded
        }
        if value.hasPrefix("'") {
            guard value.count >= 2, value.hasSuffix("'") else { throw ParseError(lineNumber, "unterminated quoted value") }
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return value
    }

    private static func stripComment(_ line: String) -> String {
        var quote: Character?
        var result = ""
        for character in line {
            if character == "\"" || character == "'" {
                if quote == character { quote = nil } else if quote == nil { quote = character }
            }
            if character == "#", quote == nil { break }
            result.append(character)
        }
        return result
    }

    private struct ParseError: LocalizedError {
        let line: Int
        let message: String
        init(_ line: Int, _ message: String) { self.line = line; self.message = message }
        var errorDescription: String? { "line \(line): \(message)" }
    }
}

struct PaletteCommandLoadResult {
    let commands: [PaletteCommand]
    let diagnostic: String?
}
