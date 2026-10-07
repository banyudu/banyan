import Foundation

public struct TelemetryConfig: Sendable, Equatable {
    public let axiomAPIToken: String?
    public let axiomOrgID: String?
    public let axiomDataset: String
    public let enabled: Bool

    public var isActive: Bool {
        guard enabled, let token = axiomAPIToken,
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return !token.contains(where: { $0.isWhitespace || $0.isNewline })
            && !axiomDataset.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !axiomDataset.contains(where: { $0.isNewline })
            && !(axiomOrgID?.contains(where: { $0.isNewline }) ?? false)
    }

    public init(
        axiomAPIToken: String? = nil,
        axiomOrgID: String? = nil,
        axiomDataset: String = "banyan-logs",
        enabled: Bool = true
    ) {
        self.axiomAPIToken = axiomAPIToken
        self.axiomOrgID = axiomOrgID
        self.axiomDataset = axiomDataset
        self.enabled = enabled
    }

    public static let disabled = TelemetryConfig(enabled: false)

    public static func load(homeDirectory: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> TelemetryConfig {
        // Dedicated file that workit sync never touches — preferred for telemetry.
        // Falls back to the legacy shared ~/.banyan/config.yml telemetry: block.
        let dedicatedURL = homeDirectory.appendingPathComponent(".banyan/telemetry.yml")
        let legacyURL = homeDirectory.appendingPathComponent(".banyan/config.yml")
        for url in [dedicatedURL, legacyURL] {
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let lines = contents.split(whereSeparator: \.isNewline).map { stripComment(String($0)) }
            if lines.contains(where: { $0.trimmingCharacters(in: .whitespaces) == "telemetry:" && !$0.hasPrefix(" ") && !$0.hasPrefix("\t") }) {
                // Explicit disabled/empty sections must win over environment
                // fallback, including when no API token is present in the file.
                return parse(contents)
            }
            if url == dedicatedURL, lines.contains(where: { line in
                let key = line.split(separator: ":", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces)
                return ["axiom_api_token", "axiom_org_id", "axiom_dataset", "enabled"].contains(key ?? "")
            }) {
                return parseFlat(contents)
            }
        }
        return configFromEnvironment(environment)
    }

    private static func configFromEnvironment(_ env: [String: String]) -> TelemetryConfig {
        let token = env["AXIOM_API_TOKEN"] ?? env["AXIOM_TOKEN"] ?? env["BANYAN_AXIOM_TOKEN"]
        guard let token, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .disabled }
        let orgID = env["AXIOM_ORG_ID"] ?? env["AXIOM_ORG"] ?? env["BANYAN_AXIOM_ORG_ID"]
        let dataset = env["AXIOM_DATASET"] ?? env["BANYAN_AXIOM_DATASET"] ?? "banyan-logs"
        return TelemetryConfig(axiomAPIToken: token, axiomOrgID: orgID, axiomDataset: dataset, enabled: true)
    }

    /// Parse a telemetry file that contains flat keys without a `telemetry:` wrapper,
    /// e.g. a dedicated ~/.banyan/telemetry.yml with just `axiom_api_token: ...`.
    static func parseFlat(_ yaml: String) -> TelemetryConfig {
        var fields: [String: String] = [:]
        for rawLine in yaml.split(whereSeparator: \.isNewline) {
            let stripped = stripComment(String(rawLine))
            let trimmed = stripped.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            // Flat file has no section header; skip lines that look like section headers
            if trimmed.hasSuffix(":") && !trimmed.contains(" ") { continue }
            guard let colonIndex = trimmed.firstIndex(of: ":") else { continue }
            let key = trimmed[..<colonIndex].trimmingCharacters(in: .whitespaces)
            let value = unquote(trimmed[trimmed.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces))
            if ["axiom_api_token", "axiom_org_id", "axiom_dataset", "enabled"].contains(key) {
                fields[key] = value
            }
        }
        guard !fields.isEmpty else { return .disabled }
        let token = fields["axiom_api_token"]
        let orgID = fields["axiom_org_id"]
        let dataset = fields["axiom_dataset"] ?? "banyan-logs"
        let enabled: Bool
        if let raw = fields["enabled"] {
            enabled = ["true", "yes", "1"].contains(raw.lowercased())
        } else {
            enabled = token != nil && !token!.isEmpty
        }
        return TelemetryConfig(axiomAPIToken: token, axiomOrgID: orgID, axiomDataset: dataset, enabled: enabled)
    }

    static func parse(_ yaml: String) -> TelemetryConfig {
        var inTelemetrySection = false
        var fields: [String: String] = [:]

        for rawLine in yaml.split(whereSeparator: \.isNewline) {
            let stripped = stripComment(String(rawLine))
            let trimmed = stripped.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let isTopLevel = !stripped.hasPrefix(" ") && !stripped.hasPrefix("\t")

            if isTopLevel {
                if trimmed == "telemetry:" {
                    inTelemetrySection = true
                    continue
                }
                if inTelemetrySection { break }
                continue
            }

            guard inTelemetrySection else { continue }
            guard let colonIndex = trimmed.firstIndex(of: ":") else { continue }
            let key = trimmed[..<colonIndex].trimmingCharacters(in: .whitespaces)
            let value = unquote(trimmed[trimmed.index(after: colonIndex)...]
                .trimmingCharacters(in: .whitespaces))
            fields[key] = value
        }

        guard !fields.isEmpty else { return .disabled }

        let token = fields["axiom_api_token"]
        let orgID = fields["axiom_org_id"]
        let dataset = fields["axiom_dataset"] ?? "banyan-logs"
        let enabled: Bool
        if let raw = fields["enabled"] {
            enabled = ["true", "yes", "1"].contains(raw.lowercased())
        } else {
            enabled = token != nil && !token!.isEmpty
        }

        return TelemetryConfig(
            axiomAPIToken: token,
            axiomOrgID: orgID,
            axiomDataset: dataset,
            enabled: enabled
        )
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

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
            (value.hasPrefix("'") && value.hasSuffix("'")) {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}
