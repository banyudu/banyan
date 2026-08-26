import AppKit
import BanyanCore
import SwiftUI

/// A user-selectable command for creating a session in a project group.
///
/// Profiles live in `~/.banyan/config.yml` (`session_launches:`) with a
/// fallback to the shared `~/.agents/agents.yml` registry (banyan-tagged
/// entries) when that section is omitted, so `workit sync` is optional.
/// Their IDs, rather than array positions or labels, are persisted per
/// project group.
struct NewSessionLaunch: Identifiable, Hashable, Codable {
    let id: String
    let label: String
    let providerName: String?
    let iconName: String?
    let command: String

    static let builtInDefaults = [
        NewSessionLaunch(id: "zsh", label: "zsh", providerName: nil, iconName: nil, command: ""),
        NewSessionLaunch(id: "claude", label: "Claude", providerName: "claude", iconName: nil, command: "claude"),
        NewSessionLaunch(id: "codex", label: "Codex", providerName: "codex", iconName: nil, command: "codex")
    ]

    var provider: CodingAgentProvider? {
        guard let providerName else { return nil }
        return CodingAgentProvider(rawValue: providerName.lowercased())
            ?? CodingAgentProvider(agentName: providerName)
    }

    /// An icon can be either an SF Symbol name or a local image path.
    /// Local paths may be absolute, start with `~`, or use a `file://` URL.
    var customIconImage: NSImage? {
        guard let url = customIconURL else { return nil }
        let image = NSImage(contentsOf: url)
        image?.size = NSSize(width: 16, height: 16)
        return image
    }

    var usesProviderIcon: Bool {
        provider != nil && (iconName == nil || customIconURL != nil)
    }

    /// A custom provider still gets a recognizable generic launch icon.
    var systemImage: String {
        guard customIconURL == nil else {
            return provider == nil && providerName == nil ? "terminal" : "sparkle"
        }
        return iconName ?? (provider == nil && providerName == nil ? "terminal" : "sparkle")
    }

    /// Keep the existing app-server preference working for the built-in Codex
    /// profile. Configured profiles otherwise run exactly their declared command.
    func resolvedCommand(codexLaunchMode: CodexLaunchMode) -> String {
        guard id == "codex", command == "codex", codexLaunchMode == .appServer else {
            return command
        }
        return AgentLaunchCommand.command(provider: .codex, codexLaunchMode: codexLaunchMode)
    }

    /// Resolve the command for Cmd+N from the selected session's full launch
    /// profile, while retaining the provider-based fallback for sessions that
    /// were not created from a configured profile.
    static func siblingCommand(
        sessionCommand: String?,
        provider: CodingAgentProvider?,
        profiles: [NewSessionLaunch],
        codexLaunchMode: CodexLaunchMode
    ) -> String {
        if let sessionCommand,
           let profile = profiles.first(where: { $0.command == sessionCommand }) {
            return profile.resolvedCommand(codexLaunchMode: codexLaunchMode)
        }
        if provider == .codex, codexLaunchMode == .appServer {
            return CodexAppServerLaunch.command()
        }
        return SessionLaunchPolicy.siblingRuntimeCommand(for: provider)
    }

    /// A leaf `Image` for a native menu item, which renders only plain images.
    var menuIconImage: Image {
        if let customIconImage {
            return Image(nsImage: customIconImage)
        }
        if let provider, usesProviderIcon {
            return providerMenuIconImage(provider: provider)
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        if let symbol = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) {
            return Image(nsImage: symbol)
        }
        return Image(systemName: systemImage)
    }

    private func providerMenuIconImage(provider: CodingAgentProvider) -> Image {
        guard let name = providerBrandResourceName(provider),
              let url = Bundle.module.url(forResource: name, withExtension: "svg"),
              let nsImage = NSImage(contentsOf: url)
        else {
            return Image(systemName: systemImage)
        }
        nsImage.size = NSSize(width: 16, height: 16)
        return Image(nsImage: nsImage)
    }

    private func providerBrandResourceName(_ provider: CodingAgentProvider) -> String? {
        switch provider {
        case .claude: return "ClaudeLogo"
        case .codex: return "ChatGPTLogo"
        case .deepseek: return "DeepSeekLogo"
        case .gemini: return "GeminiLogo"
        case .hunyuan: return "HunyuanLogo"
        case .minimax: return "MiniMaxLogo"
        case .muse: return "MuseLogo"
        case .xiaomiMiMo: return "XiaomiMiMoLogo"
        case .zai: return "ZAILogo"
        case .opencode: return nil
        }
    }

    private var customIconURL: URL? {
        guard let iconName, !iconName.isEmpty else { return nil }
        if iconName.hasPrefix("file://") {
            return URL(string: iconName)
        }
        if iconName.hasPrefix("/") {
            return URL(fileURLWithPath: iconName)
        }
        if iconName == "~" {
            return URL(fileURLWithPath: NSHomeDirectory())
        }
        if iconName.hasPrefix("~/") {
            return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(String(iconName.dropFirst(2)))
        }
        return nil
    }
}

struct SessionLaunchProfileLoadResult {
    let profiles: [NewSessionLaunch]
    let diagnostic: String?
}

/// Minimal, deliberately strict YAML reader for Banyan's small configuration
/// surface. Keeping this format flat means commands remain opaque strings and
/// avoids adding a general-purpose parser to the app.
enum SessionLaunchProfileLoader {
    static func configURL(homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent(".banyan/config.yml")
    }

    static func agentsURL(homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent(".agents/agents.yml")
    }

    /// Preferred load path that honours the shared `~/.agents/agents.yml` registry.
    /// If `~/.banyan/config.yml` contains a `session_launches:` section it is used
    /// verbatim (with built-in merge). Otherwise the loader falls back to the
    /// registry's `banyan`-tagged agents so `workit sync` is no longer required
    /// for the picker.
    static func load(
        homeDirectory: URL,
        fileManager: FileManager = .default
    ) -> SessionLaunchProfileLoadResult {
        let configURL = configURL(homeDirectory: homeDirectory)
        let agentsURL = agentsURL(homeDirectory: homeDirectory)

        // 1. Try the explicit Banyan config if it defines session_launches.
        if fileManager.fileExists(atPath: configURL.path),
           let contents = try? String(contentsOf: configURL, encoding: .utf8),
           contents.contains("session_launches:") {
            do {
                var profiles = try parse(contents)
                let existingIDs = Set(profiles.map(\.id))
                for builtIn in NewSessionLaunch.builtInDefaults where !existingIDs.contains(builtIn.id) {
                    profiles.append(builtIn)
                }
                return SessionLaunchProfileLoadResult(profiles: profiles, diagnostic: nil)
            } catch {
                return SessionLaunchProfileLoadResult(
                    profiles: NewSessionLaunch.builtInDefaults,
                    diagnostic: "Could not load session launch profiles from \(configURL.path): \(error.localizedDescription). Using built-in defaults."
                )
            }
        }

        // 2. Config missing or without session_launches: try the shared registry.
        if fileManager.fileExists(atPath: agentsURL.path) {
            do {
                let contents = try String(contentsOf: agentsURL, encoding: .utf8)
                var profiles = try parseAgents(contents)
                // Merge built-ins that the registry doesn't list (e.g. a fresh home).
                let existingIDs = Set(profiles.map(\.id))
                for builtIn in NewSessionLaunch.builtInDefaults where !existingIDs.contains(builtIn.id) {
                    profiles.append(builtIn)
                }
                if !profiles.isEmpty {
                    return SessionLaunchProfileLoadResult(profiles: profiles, diagnostic: nil)
                }
            } catch {
                return SessionLaunchProfileLoadResult(
                    profiles: NewSessionLaunch.builtInDefaults,
                    diagnostic: "Could not load session launch profiles from \(agentsURL.path): \(error.localizedDescription). Using built-in defaults."
                )
            }
        }

        // 3. Config without session_launches and no usable registry: if config
        //    exists but had no session_launches, that was an intentional omission
        //    — don't surface a diagnostic, just use built-ins. Otherwise the
        //    file was missing entirely, also use built-ins quietly.
        if fileManager.fileExists(atPath: configURL.path) {
            // Valid config file without session_launches and no registry: use built-ins.
            // If the file was present but empty/invalid without the key, don't treat as error.
            if let contents = try? String(contentsOf: configURL, encoding: .utf8),
               !contents.contains("session_launches:") {
                return SessionLaunchProfileLoadResult(profiles: NewSessionLaunch.builtInDefaults, diagnostic: nil)
            }
        }

        return SessionLaunchProfileLoadResult(profiles: NewSessionLaunch.builtInDefaults, diagnostic: nil)
    }

    static func load(
        at url: URL,
        fileManager: FileManager = .default
    ) -> SessionLaunchProfileLoadResult {
        // Direct URL load retains the old strict contract for tests and callers
        // that manage their own path. No agents fallback here to keep those
        // isolates deterministic.
        guard fileManager.fileExists(atPath: url.path) else {
            return SessionLaunchProfileLoadResult(profiles: NewSessionLaunch.builtInDefaults, diagnostic: nil)
        }
        do {
            let contents = try String(contentsOf: url, encoding: .utf8)
            var profiles = try parse(contents)
            // Merge any new built-in profiles that the user's config doesn't yet
            // contain, so additions like hunyuan/muse appear without manual edits.
            // Existing entries keep their order and customization; new ones append.
            let existingIDs = Set(profiles.map(\.id))
            for builtIn in NewSessionLaunch.builtInDefaults where !existingIDs.contains(builtIn.id) {
                profiles.append(builtIn)
            }
            return SessionLaunchProfileLoadResult(profiles: profiles, diagnostic: nil)
        } catch {
            return SessionLaunchProfileLoadResult(
                profiles: NewSessionLaunch.builtInDefaults,
                diagnostic: "Could not load session launch profiles from \(url.path): \(error.localizedDescription). Using built-in defaults."
            )
        }
    }

    static func parse(_ yaml: String) throws -> [NewSessionLaunch] {
        var fields: [[String: String]] = []
        var current: [String: String]?
        var foundSection = false

        for (offset, rawLine) in yaml.split(whereSeparator: \.isNewline).enumerated() {
            let lineNumber = offset + 1
            let line = stripComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line == "session_launches:" {
                guard !foundSection, current == nil else { throw ParseError(lineNumber, "duplicate session_launches section") }
                foundSection = true
                continue
            }
            guard foundSection else { throw ParseError(lineNumber, "expected session_launches:") }
            if line.hasPrefix("-") {
                if let current { fields.append(current) }
                let remainder = line.dropFirst().trimmingCharacters(in: .whitespaces)
                guard !remainder.isEmpty else {
                    current = [:]
                    continue
                }
                current = try parseField(String(remainder), lineNumber: lineNumber)
            } else {
                guard var item = current else { throw ParseError(lineNumber, "expected a profile entry") }
                let field = try parseField(line, lineNumber: lineNumber)
                for (key, value) in field {
                    guard item[key] == nil else { throw ParseError(lineNumber, "duplicate \(key) field") }
                    item[key] = value
                }
                current = item
            }
        }
        if let current { fields.append(current) }
        guard foundSection else { throw ParseError(1, "missing session_launches section") }
        guard !fields.isEmpty else { throw ParseError(1, "session_launches must contain at least one profile") }

        var ids = Set<String>()
        return try fields.enumerated().map { index, item in
            guard let id = item["id"]?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty,
                  let label = item["label"]?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty,
                  let command = item["command"]
            else { throw ParseError(index + 1, "each profile requires non-empty id, label, and command") }
            guard ids.insert(id).inserted else { throw ParseError(index + 1, "duplicate profile id '\(id)'") }
            return NewSessionLaunch(
                id: id,
                label: label,
                providerName: item["provider"],
                iconName: item["icon"],
                command: command
            )
        }
    }

    private static func parseField(_ line: String, lineNumber: Int) throws -> [String: String] {
        guard let separator = line.firstIndex(of: ":") else { throw ParseError(lineNumber, "expected key: value") }
        let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
        guard ["id", "label", "provider", "icon", "command"].contains(key) else { throw ParseError(lineNumber, "unknown field '\(key)'") }
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

    /// Parse the shared `~/.agents/agents.yml` registry into picker profiles.
    /// Mirrors `workit`'s `banyanProfiles()` selection: only `banyan`-tagged
    /// entries with `picker !== false` and a defined `command` are surfaced, in
    /// registry order, using `banyanCommand` when present.
    static func parseAgents(_ yaml: String) throws -> [NewSessionLaunch] {
        var profiles: [NewSessionLaunch] = []
        var inAgentsSection = false
        var currentID: String?
        var currentLabel: String?
        var currentProvider: String?
        var currentIcon: String?
        var currentCommand: String?
        var currentBanyanCommand: String?
        var currentTags: [String]?
        var currentPickerIsFalse = false
        var skippingOpencodeDepth: Int?
        var foundAgentsSection = false

        func flushCurrent() {
            guard let id = currentID else { return }
            // Replicate workit filtering
            let tags = currentTags ?? []
            let isBanyan = tags.contains("banyan")
            let hasCommand = currentCommand != nil || currentBanyanCommand != nil
            if !isBanyan || currentPickerIsFalse || !hasCommand {
                return
            }
            let command = currentBanyanCommand ?? currentCommand ?? ""
            let label = (currentLabel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? currentLabel! : id
            profiles.append(NewSessionLaunch(
                id: id,
                label: label,
                providerName: currentProvider,
                iconName: currentIcon,
                command: command
            ))
        }

        for rawLine in yaml.split(whereSeparator: \.isNewline) {
            let raw = String(rawLine)
            let uncommented = stripComment(raw)
            let trimmed = uncommented.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let indent = raw.prefix(while: { $0 == " " }).count
            let isTopLevel = indent == 0

            if isTopLevel {
                if trimmed == "agents:" {
                    // leaving previous top-level, flush any pending agent
                    if inAgentsSection { flushCurrent(); currentID = nil }
                    inAgentsSection = true
                    foundAgentsSection = true
                    currentID = nil
                    currentLabel = nil
                    currentProvider = nil
                    currentIcon = nil
                    currentCommand = nil
                    currentBanyanCommand = nil
                    currentTags = nil
                    currentPickerIsFalse = false
                    skippingOpencodeDepth = nil
                    continue
                }
                if trimmed.contains(":") {
                    if inAgentsSection {
                        flushCurrent()
                        currentID = nil
                        inAgentsSection = false
                        skippingOpencodeDepth = nil
                    }
                    continue
                }
            }

            guard inAgentsSection else { continue }

            if let depth = skippingOpencodeDepth {
                if indent > depth {
                    continue
                } else {
                    skippingOpencodeDepth = nil
                }
            }

            if indent == 2 {
                // New agent entry: `  name:`
                flushCurrent()
                // Parse id — must end with colon
                guard trimmed.hasSuffix(":") else { continue }
                let idPart = String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces)
                // Strip quotes if any
                let id: String
                if (idPart.hasPrefix("\"") && idPart.hasSuffix("\"")) || (idPart.hasPrefix("'") && idPart.hasSuffix("'")) {
                    id = String(idPart.dropFirst().dropLast())
                } else {
                    id = idPart
                }
                guard !id.isEmpty else { continue }
                currentID = id
                currentLabel = nil
                currentProvider = nil
                currentIcon = nil
                currentCommand = nil
                currentBanyanCommand = nil
                currentTags = nil
                currentPickerIsFalse = false
                continue
            }

            guard currentID != nil, indent == 4 else { continue }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            let rawValue = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)

            switch key {
            case "label":
                currentLabel = (try? scalar(rawValue, lineNumber: 1)) ?? rawValue
            case "provider":
                currentProvider = (try? scalar(rawValue, lineNumber: 1)) ?? rawValue
            case "icon":
                currentIcon = (try? scalar(rawValue, lineNumber: 1)) ?? rawValue
            case "command":
                currentCommand = (try? scalar(rawValue, lineNumber: 1)) ?? rawValue
            case "banyanCommand":
                currentBanyanCommand = (try? scalar(rawValue, lineNumber: 1)) ?? rawValue
            case "tags":
                // Expected form: [banyan, coding] — extract inside brackets
                if let start = rawValue.firstIndex(of: "["), let end = rawValue.firstIndex(of: "]") {
                    let inner = String(rawValue[rawValue.index(after: start)..<end])
                    let tags = inner.split(separator: ",").map { part in
                        part.trimmingCharacters(in: .whitespacesAndNewlines)
                            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    }.filter { !$0.isEmpty }
                    currentTags = tags
                } else if rawValue.isEmpty {
                    currentTags = []
                } else {
                    currentTags = []
                }
            case "picker":
                let v = (try? scalar(rawValue, lineNumber: 1)) ?? rawValue
                currentPickerIsFalse = v.lowercased() == "false"
            case "opencode":
                skippingOpencodeDepth = 4
            default:
                continue
            }
        }
        flushCurrent()
        guard foundAgentsSection else { throw ParseError(1, "missing agents section") }
        return profiles
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
