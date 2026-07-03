import Foundation

struct AgentStateDetector {
    struct Result {
        let status: SessionStatus
        let tone: SessionTone
    }

    private let rules: [DetectorRule]

    init(rules: [DetectorRule] = DetectorRule.loadConfiguredRules()) {
        self.rules = rules
    }

    func detect(in text: String) -> Result? {
        let lowercased = text.lowercased()
        for rule in rules where rule.matches(lowercased) {
            return Result(status: rule.status, tone: rule.tone)
        }
        return nil
    }
}

struct DetectorRule: Codable {
    let status: SessionStatus
    let tone: SessionTone
    let patterns: [String]

    func matches(_ text: String) -> Bool {
        patterns.contains { text.contains($0) }
    }

    static func loadConfiguredRules() -> [DetectorRule] {
        let url = rulesFileURL()
        if let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            if let rules = try? decoder.decode([DetectorRule].self, from: data), !rules.isEmpty {
                return rules
            }
        }
        return defaultRules
    }

    static let defaultRules: [DetectorRule] = [
        DetectorRule(status: .asking, tone: .yellow, patterns: [
            "do you want", "would you like", "should i", "can i",
            "approve", "permission required", "approval required"
        ]),
        DetectorRule(status: .needInput, tone: .yellow, patterns: [
            "needs input", "need input", "waiting for input", "press enter",
            "waiting (", "press any key"
        ])
    ]

    static func rulesFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Banyan/detectors.json")
    }
}
