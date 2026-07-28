import Foundation

public struct AgentStateDetector: Sendable {
    public struct Result: Sendable {
        public let status: SessionStatus
        public let tone: SessionTone
    }

    private let rules: [DetectorRule]

    public init(rules: [DetectorRule]) {
        self.rules = rules
    }

    public func detect(in text: String) -> Result? {
        let lowercased = text.lowercased()
        for rule in rules where rule.matches(lowercased) {
            return Result(status: rule.status, tone: rule.tone)
        }
        return nil
    }
}

public struct DetectorRule: Codable, Sendable {
    public let status: SessionStatus
    public let tone: SessionTone
    public let patterns: [String]

    public init(status: SessionStatus, tone: SessionTone, patterns: [String]) {
        self.status = status
        self.tone = tone
        self.patterns = patterns
    }

    public func matches(_ text: String) -> Bool {
        patterns.contains { text.contains($0) }
    }

    public static func loadConfiguredRules(
        environment: [String: String],
        homeDirectory: URL
    ) -> [DetectorRule] {
        let url = rulesFileURL(environment: environment, homeDirectory: homeDirectory)
        if let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            if let rules = try? decoder.decode([DetectorRule].self, from: data), !rules.isEmpty {
                return rules
            }
        }
        return defaultRules
    }

    public static let defaultRules: [DetectorRule] = [
        DetectorRule(status: .asking, tone: .yellow, patterns: [
            "do you want", "would you like", "should i", "can i",
            "approve", "permission required", "approval required"
        ]),
        DetectorRule(status: .needInput, tone: .yellow, patterns: [
            "needs input", "need input", "waiting for input", "press enter",
            "waiting (", "press any key"
        ])
    ]

    public static func rulesFileURL(
        environment: [String: String],
        homeDirectory: URL
    ) -> URL {
        BanyanDataDirectory.url(
            for: "Banyan/detectors.json",
            environment: environment,
            homeDirectory: homeDirectory
        )
    }
}
