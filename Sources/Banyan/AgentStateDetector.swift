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
        DetectorRule(status: .needInput, tone: .yellow, patterns: [
            "needs input", "need input", "waiting for input", "approval required",
            "permission required", "press enter", "waiting ("
        ]),
        DetectorRule(status: .review, tone: .purple, patterns: [
            "review needed", "ready for review", "please review", "needs review"
        ]),
        DetectorRule(status: .failed, tone: .red, patterns: [
            "build failed", "tests failed", "fatal:", "error:", "exception:", "traceback"
        ]),
        DetectorRule(status: .completed, tone: .green, patterns: [
            "build complete!", "tests passed", "all tests passed",
            "implementation complete", "completed successfully"
        ])
    ]

    static func rulesFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Banyan/detectors.json")
    }
}
