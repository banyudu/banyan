import Testing
@testable import BanyanCore

@Test func agentStateDetectorKeepsInputPromptsVisible() {
    let detector = AgentStateDetector(rules: DetectorRule.defaultRules)

    let result = detector.detect(in: "The task is waiting for input")

    #expect(result?.status == .needInput)
    #expect(result?.tone == .yellow)
}

@Test func agentStateDetectorUsesFirstMatchingRule() {
    let rules = [
        DetectorRule(status: .review, tone: .purple, patterns: ["ready"]),
        DetectorRule(status: .asking, tone: .yellow, patterns: ["ready"])
    ]

    #expect(AgentStateDetector(rules: rules).detect(in: "ready")?.status == .review)
}
