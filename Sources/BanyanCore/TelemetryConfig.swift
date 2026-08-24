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
        let configURL = homeDirectory.appendingPathComponent(".banyan/config.yml")
        guard FileManager.default.fileExists(atPath: configURL.path) else { return .disabled }
        do {
            let contents = try String(contentsOf: configURL, encoding: .utf8)
            return parse(contents)
        } catch {
            NSLog("Banyan: failed to read telemetry config: \(error.localizedDescription)")
            return .disabled
        }
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
