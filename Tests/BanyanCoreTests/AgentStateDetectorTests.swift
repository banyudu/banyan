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

/// Matching runs over UTF-8 bytes with ASCII case folding rather than
/// `String.lowercased()`, so the cases that folding used to cover need pinning.
@Test func agentStateDetectorMatchesRegardlessOfCase() {
    let detector = AgentStateDetector(rules: DetectorRule.defaultRules)

    #expect(detector.detect(in: "Do You Want to continue?")?.status == .asking)
    #expect(detector.detect(in: "PRESS ENTER to retry")?.status == .needInput)
}

@Test func agentStateDetectorMatchesAtTheVeryStartAndEnd() {
    let rules = [DetectorRule(status: .asking, tone: .yellow, patterns: ["approve"])]
    let detector = AgentStateDetector(rules: rules)

    #expect(detector.detect(in: "approve") != nil)
    #expect(detector.detect(in: "Approve this") != nil)
    #expect(detector.detect(in: "please approve") != nil)
    #expect(detector.detect(in: "appro") == nil)
    #expect(detector.detect(in: "") == nil)
}

@Test func agentStateDetectorIgnoresNearMissesBeforeARealMatch() {
    let rules = [DetectorRule(status: .asking, tone: .yellow, patterns: ["abcabd"])]
    let detector = AgentStateDetector(rules: rules)

    // A partial match must not consume the bytes that start the real one.
    #expect(detector.detect(in: "abcabcabd") != nil)
    #expect(detector.detect(in: "abcabc") == nil)
}

/// Non-ASCII patterns cannot be case-folded byte-wise, so they keep the original
/// String-based path. Matching must still work for them.
@Test func agentStateDetectorSupportsNonASCIIPatterns() {
    let rules = [DetectorRule(status: .needInput, tone: .yellow, patterns: ["需要输入"])]
    let detector = AgentStateDetector(rules: rules)

    #expect(detector.detect(in: "代理需要输入内容")?.status == .needInput)
    #expect(detector.detect(in: "nothing here") == nil)
}

/// Multi-byte text in the haystack must not be able to produce a false ASCII match
/// or read past the end of the buffer.
@Test func agentStateDetectorHandlesMultibyteHaystacks() {
    let detector = AgentStateDetector(rules: DetectorRule.defaultRules)

    #expect(detector.detect(in: "构建完成 ✅ 没有问题") == nil)
    #expect(detector.detect(in: "构建失败 — do you want to retry?")?.status == .asking)
}
