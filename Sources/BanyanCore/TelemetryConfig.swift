import Foundation

public struct TelemetryConfig: Sendable, Equatable {
    public let axiomAPIToken: String?
    public let axiomOrgID: String?
    public let axiomDataset: String
    public let enabled: Bool

    public var isActive: Bool {
        enabled && axiomAPIToken != nil && !axiomAPIToken!.isEmpty
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

    public static func load(homeDirectory: URL) -> TelemetryConfig {
        // Dedicated file that workit sync never touches — preferred for telemetry.
        // Falls back to the legacy shared ~/.banyan/config.yml telemetry: block.
        let dedicatedURL = homeDirectory.appendingPathComponent(".banyan/telemetry.yml")
        let legacyURL = homeDirectory.appendingPathComponent(".banyan/config.yml")
        let envConfig = configFromEnvironment()

        for url in [dedicatedURL, legacyURL] {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                let contents = try String(contentsOf: url, encoding: .utf8)
                let parsed = parse(contents)
                if parsed.isActive || !parsed.axiomDataset.isEmpty && parsed.axiomAPIToken != nil {
                    // Return parsed even if disabled explicitly, so enabled:false is honored.
                    // Fall through to env fallback only when file has no telemetry section.
                    if parsed.axiomAPIToken != nil || contents.contains("telemetry:") {
                        return parsed
                    }
                }
                // If file exists but has no telemetry section, treat as no-config and try next.
                if parsed != .disabled { return parsed }
                // For dedicated file, also support flat keys without telemetry: wrapper
                let flat = parseFlat(contents)
                if flat != .disabled { return flat }
            } catch {
                NSLog("Banyan: failed to read telemetry config at \(url.path): \(error.localizedDescription)")
                continue
            }
        }

        // Env fallback allows AXIOM_API_TOKEN to work without any file, e.g. in CI.
        if envConfig.isActive { return envConfig }
        // If dedicated file had flat keys, envConfig may have dataset/org from file + token from env — merge.
        if let dedicatedContents = try? String(contentsOf: dedicatedURL, encoding: .utf8) {
            let flat = parseFlat(dedicatedContents)
            if flat.axiomAPIToken == nil, let token = envConfig.axiomAPIToken {
                return TelemetryConfig(axiomAPIToken: token, axiomOrgID: flat.axiomOrgID ?? envConfig.axiomOrgID, axiomDataset: flat.axiomDataset, enabled: true)
            }
        }

        return .disabled
    }

    private static func configFromEnvironment() -> TelemetryConfig {
        let env = ProcessInfo.processInfo.environment
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
