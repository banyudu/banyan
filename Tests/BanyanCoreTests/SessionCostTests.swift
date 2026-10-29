import Foundation
import Testing
@testable import BanyanCore

private func temporaryTranscript(_ lines: [String]) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("banyan-cost-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("transcript.jsonl")
    try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
    return url
}

private func estimate(_ records: [SessionCostUsageRecord]) -> SessionCostEstimate {
    SessionCostCalculator.estimate(transcript: SessionCostTranscript(records: records))
}

private func record(
    _ modelID: String,
    uncachedInput: Int = 0,
    cachedInput: Int = 0,
    cacheWrite: Int = 0,
    output: Int = 0,
    serviceTier: String? = nil,
    inferenceGeography: String? = nil,
    speed: String? = nil,
    timestamp: Date = Date(timeIntervalSince1970: 1_790_000_000)
) -> SessionCostUsageRecord {
    SessionCostUsageRecord(
        modelID: modelID,
        timestamp: timestamp,
        usage: SessionTokenUsage(
            uncachedInput: uncachedInput,
            cachedInput: cachedInput,
            cacheWrite: cacheWrite,
            output: output
        ),
        serviceTier: serviceTier,
        inferenceGeography: inferenceGeography,
        speed: speed
    )
}

private func date(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value)!
}

@Test func codexDeduplicatesResponsesAndUsesTurnModel() throws {
    let url = try temporaryTranscript([
        #"{"timestamp":"2026-09-25T01:19:02.000Z","type":"turn_context","payload":{"turn_id":"turn-a","model":"gpt-6.1-sol"}}"#,
        #"{"timestamp":"2026-09-25T01:19:07.000Z","type":"token_usage_record","payload":{"turn_id":"turn-a","response_id":"response-a","usage":{"input_tokens":1000000,"cached_input_tokens":400000,"cache_write_input_tokens":100000,"output_tokens":50000,"reasoning_output_tokens":5000}}}"#,
        #"{"timestamp":"2026-09-25T01:19:07.001Z","type":"token_usage_record","payload":{"turn_id":"turn-a","response_id":"response-a","usage":{"input_tokens":1000000,"cached_input_tokens":400000,"cache_write_input_tokens":100000,"output_tokens":50000,"reasoning_output_tokens":5000}}}"#
    ])
    let transcript = try #require(SessionTranscriptCostReader.read(
        url: url,
        provider: .codex,
        startingAt: 0,
        previous: nil
    ))
    #expect(transcript.transcript.records.count == 1)
    let usage = transcript.transcript.records[0].usage
    #expect(transcript.transcript.records[0].modelID == "gpt-6.1-sol")
    #expect(usage.uncachedInput == 500000)
    #expect(usage.cachedInput == 400000)
    #expect(usage.cacheWrite == 100000)
    #expect(usage.output == 50000)
    #expect(usage.totalTokens == 1050000)
}

@Test func codexCumulativeFallbackUsesHighWaterAndIgnoresRepeatedLastUsage() throws {
    let url = try temporaryTranscript([
        #"{"timestamp":"2026-06-25T15:04:54.000Z","type":"turn_context","payload":{"turn_id":"turn-a","model":"gpt-5.5"}}"#,
        #"{"timestamp":"2026-06-25T15:05:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":100,"cache_write_input_tokens":0,"output_tokens":100},"last_token_usage":{"input_tokens":1000,"cached_input_tokens":100,"cache_write_input_tokens":0,"output_tokens":100}}}}"#,
        #"{"timestamp":"2026-06-25T15:05:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":100,"cache_write_input_tokens":0,"output_tokens":100},"last_token_usage":{"input_tokens":1000,"cached_input_tokens":100,"cache_write_input_tokens":0,"output_tokens":100}}}}"#,
        #"{"timestamp":"2026-06-25T15:05:02.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":3000,"cached_input_tokens":500,"cache_write_input_tokens":0,"output_tokens":300},"last_token_usage":{"input_tokens":2000,"cached_input_tokens":400,"cache_write_input_tokens":0,"output_tokens":200}}}}"#
    ])
    let transcript = try #require(SessionTranscriptCostReader.read(
        url: url,
        provider: .codex,
        startingAt: 0,
        previous: nil
    ))
    #expect(transcript.transcript.records.count == 2)
    #expect(transcript.transcript.records[0].usage.uncachedInput == 900)
    #expect(transcript.transcript.records[0].usage.output == 100)
    #expect(transcript.transcript.records[1].usage.uncachedInput == 1600)
    #expect(transcript.transcript.records[1].usage.cachedInput == 400)
    #expect(transcript.transcript.records[1].usage.output == 200)
}

@Test func claudeDeduplicatesMessagesAndPreservesCacheSplitAndModifiers() throws {
    let row = #"{"type":"assistant","timestamp":"2026-10-01T00:00:00.000Z","message":{"id":"msg-a","model":"claude-opus-5-5","usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":300,"cache_read_input_tokens":200,"cache_creation":{"ephemeral_5m_input_tokens":100,"ephemeral_1h_input_tokens":200},"service_tier":"standard","inference_geo":"not_available","speed":"standard"}}}"#
    let url = try temporaryTranscript([
        row,
        row.replacingOccurrences(of: "00:00:00.000Z", with: "00:00:01.000Z"),
        #"{"type":"assistant","timestamp":"2026-10-01T00:00:02.000Z","message":{"id":"msg-b","model":"<synthetic>","usage":{"input_tokens":10,"output_tokens":10}}}"#
    ])
    let transcript = try #require(SessionTranscriptCostReader.read(
        url: url,
        provider: .claude,
        startingAt: 0,
        previous: nil
    ))
    let usageRecord = try #require(transcript.transcript.records.first)
    #expect(transcript.transcript.records.count == 1)
    #expect(usageRecord.usage.uncachedInput == 100)
    #expect(usageRecord.usage.cachedInput == 200)
    #expect(usageRecord.usage.cacheWrite == 300)
    #expect(usageRecord.cacheWrite5m == 100)
    #expect(usageRecord.cacheWrite1h == 200)
    #expect(usageRecord.serviceTier == "standard")
    #expect(usageRecord.inferenceGeography == "not_available")
    #expect(usageRecord.speed == "standard")
    #expect(estimate([usageRecord]) == .complete(
        amount: Decimal(string: "0.00354")!,
        tint: .claude
    ))
}

@Test func unsupportedModelNeverBecomesZero() {
    #expect(estimate([record("unknown-model", uncachedInput: 100, output: 10)])
        == .unavailable(.unknownModel("unknown-model")))
}

@Test func mixedProviderTranscriptUsesNeutralMixedTint() {
    #expect(estimate([
        record("gpt-6.1-sol", uncachedInput: 1_000_000),
        record("claude-opus-5-5", uncachedInput: 1_000_000)
    ]) == .complete(amount: 8, tint: .mixed))
}

@Test func displayUsesCompactDollarAmount() {
    #expect(SessionCostDisplay(amount: Decimal(string: "1.234")!).text == "$1.2")
    #expect(SessionCostDisplay(amount: Decimal(string: "0.42")!).text == "$0.42")
    #expect(SessionCostDisplay(amount: Decimal(string: "0.0001")!).text == "<$0.01")
    #expect(SessionCostDisplay(amount: Decimal(string: "123.4")!).text == "$123")
}

@Test func residentCostTierMarksExpensiveAndCriticalEstimates() {
    #expect(SessionCostTier(estimate: nil) == .standard)
    #expect(SessionCostTier(estimate: .unavailable(.noUsage)) == .standard)
    #expect(SessionCostTier(estimate: .complete(
        amount: Decimal(string: "19.99")!,
        tint: .codex
    )) == .standard)
    #expect(SessionCostTier(estimate: .complete(amount: 20, tint: .codex)) == .expensive)
    #expect(SessionCostTier(estimate: .complete(
        amount: Decimal(string: "99.99")!,
        tint: .claude
    )) == .expensive)
    #expect(SessionCostTier(estimate: .complete(amount: 100, tint: .codex)) == .expensive)
    #expect(SessionCostTier(estimate: .complete(
        amount: Decimal(string: "100.01")!,
        tint: .codex
    )) == .critical)
    #expect(SessionCostTier(estimate: .complete(amount: 150, tint: .claude)) == .critical)
}

@Test func incrementalReaderResumesOnlyCompleteLines() throws {
    let url = try temporaryTranscript([
        #"{"type":"assistant","timestamp":"2026-10-01T00:00:00.000Z","message":{"id":"msg-a","model":"claude-opus-5-5","usage":{"input_tokens":100,"output_tokens":50}}}"#
    ])
    let first = try #require(SessionTranscriptCostReader.read(
        url: url,
        provider: .claude,
        startingAt: 0,
        previous: nil
    ))
    try ( #"{"type":"assistant","timestamp":"2026-10-01T00:00:01.000Z","message":{"id":"msg-b","model":"claude-opus-5-5","usage":{"input_tokens":100,"output_tokens":50}}}"# + "\n" )
        .append(to: url)
    let second = try #require(SessionTranscriptCostReader.read(
        url: url,
        provider: .claude,
        startingAt: first.consumedOffset,
        previous: first.transcript
    ))
    #expect(second.transcript.records.count == 2)
}

@Test func incrementalReaderPreservesDeduplicationTurnAndTierState() throws {
    let url = try temporaryTranscript([
        #"{"timestamp":"2026-09-25T01:19:02.000Z","type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"model":"gpt-6.1-sol","service_tier":"default"}}}"#,
        #"{"timestamp":"2026-09-25T01:19:02.000Z","type":"turn_context","payload":{"turn_id":"turn-a","model":"gpt-6.1-sol"}}"#,
        #"{"timestamp":"2026-09-25T01:19:07.000Z","type":"token_usage_record","payload":{"turn_id":"turn-a","response_id":"response-a","usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":10}}}"#
    ])
    let first = try #require(SessionTranscriptCostReader.read(
        url: url,
        provider: .codex,
        startingAt: 0,
        previous: nil
    ))
    try ( #"{"timestamp":"2026-09-25T01:19:08.000Z","type":"token_usage_record","payload":{"turn_id":"turn-a","response_id":"response-a","usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":10}}}"# + "\n" )
        .append(to: url)
    let second = try #require(SessionTranscriptCostReader.read(
        url: url,
        provider: .codex,
        startingAt: first.consumedOffset,
        previous: first.transcript
    ))
    #expect(second.transcript.records.count == 1)
    #expect(second.transcript.records[0].modelID == "gpt-6.1-sol")
    #expect(second.transcript.records[0].serviceTier == "default")
}

@Test func additiveCodexRecordsSupersedeAnOlderCumulativePrefix() throws {
    let url = try temporaryTranscript([
        #"{"timestamp":"2026-06-25T15:04:54.000Z","type":"turn_context","payload":{"turn_id":"turn-a","model":"gpt-5.5"}}"#,
        #"{"timestamp":"2026-06-25T15:05:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":100,"cache_write_input_tokens":0,"output_tokens":100}}}}"#,
        #"{"timestamp":"2026-06-25T15:05:01.000Z","type":"token_usage_record","payload":{"turn_id":"turn-a","response_id":"response-a","usage":{"input_tokens":1000,"cached_input_tokens":100,"cache_write_input_tokens":0,"output_tokens":100}}}"#
    ])
    let transcript = try #require(SessionTranscriptCostReader.read(
        url: url,
        provider: .codex,
        startingAt: 0,
        previous: nil
    ))
    #expect(transcript.transcript.records.count == 1)
    #expect(transcript.transcript.records[0].usage.uncachedInput == 900)
    #expect(transcript.transcript.records[0].usage.output == 100)
}

@Test func codexModelSwitchPricesEachTurnByItsRecordedModel() throws {
    let url = try temporaryTranscript([
        #"{"timestamp":"2026-10-24T12:00:00.000Z","type":"turn_context","payload":{"turn_id":"turn-a","model":"gpt-6.1-sol"}}"#,
        #"{"timestamp":"2026-10-24T12:00:01.000Z","type":"token_usage_record","payload":{"turn_id":"turn-a","response_id":"response-a","usage":{"input_tokens":100000,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":0}}}"#,
        #"{"timestamp":"2026-10-24T12:00:02.000Z","type":"turn_context","payload":{"turn_id":"turn-b","model":"deepseek-v4.1-flash"}}"#,
        #"{"timestamp":"2026-10-24T12:00:03.000Z","type":"token_usage_record","payload":{"turn_id":"turn-b","response_id":"response-b","usage":{"input_tokens":100000,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":0}}}"#
    ])
    let transcript = try #require(SessionTranscriptCostReader.read(
        url: url,
        provider: .codex,
        startingAt: 0,
        previous: nil
    ))
    #expect(transcript.transcript.records.map(\.modelID) == ["gpt-6.1-sol", "deepseek-v4.1-flash"])
    #expect(SessionCostCalculator.estimate(transcript: transcript.transcript)
        == .complete(amount: Decimal(string: "0.215")!, tint: .mixed))
}

@Test func costCacheReloadsAfterTranscriptReplacement() throws {
    let original = #"{"type":"assistant","timestamp":"2026-10-01T00:00:00.000Z","message":{"id":"msg-a","model":"claude-opus-5-5","usage":{"input_tokens":100,"output_tokens":50}}}"#
    let replacement = #"{"type":"assistant","timestamp":"2026-10-01T00:00:01.000Z","message":{"id":"msg-b","model":"claude-opus-5-5","usage":{"input_tokens":200,"output_tokens":100}}}"#
    let url = try temporaryTranscript([original])
    let cache = SessionCostCache()

    let first = try #require(cache.transcript(at: url, provider: .claude))
    #expect(first.records.first?.modelID == "claude-opus-5-5")
    try replacement.appending("\n").write(to: url, atomically: true, encoding: .utf8)

    let second = try #require(cache.transcript(at: url, provider: .claude))
    #expect(second.records.count == 1)
    #expect(second.records.first?.usage.uncachedInput == 200)
    #expect(second.records.first?.usage.output == 100)
}

@Test func costCacheResetsAfterInPlaceRewritePastTheOldOffset() throws {
    let original = #"{"type":"assistant","timestamp":"2026-10-01T00:00:00.000Z","message":{"id":"msg-a","model":"claude-opus-5-5","usage":{"input_tokens":100,"output_tokens":50}}}"#
    let firstReplacement = #"{"type":"assistant","timestamp":"2026-10-01T00:00:01.000Z","message":{"id":"msg-b","model":"claude-opus-5-5","usage":{"input_tokens":200,"output_tokens":100}}}"#
    let secondReplacement = #"{"type":"assistant","timestamp":"2026-10-01T00:00:02.000Z","message":{"id":"msg-c","model":"claude-opus-5-5","usage":{"input_tokens":300,"output_tokens":150}}}"#
    let url = try temporaryTranscript([original])
    let cache = SessionCostCache()
    _ = try #require(cache.transcript(at: url, provider: .claude))

    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.truncate(atOffset: 0)
    try handle.write(contentsOf: Data("\(firstReplacement)\n\(secondReplacement)\n".utf8))

    let rewritten = try #require(cache.transcript(at: url, provider: .claude))
    #expect(rewritten.records.count == 2)
    #expect(rewritten.records.map(\.usage.uncachedInput) == [200, 300])
}

@Test func resolverRequiresExactProviderAndSessionIdentity() {
    let url = URL(fileURLWithPath: "/tmp/thread.jsonl")
    let imported = ImportedAgentSession(
        id: "codex:thread-a",
        provider: .codex,
        sourceID: "thread-a",
        title: "Thread",
        cwd: "/tmp",
        transcriptURL: url,
        createdAt: Date(timeIntervalSince1970: 0),
        updatedAt: Date(timeIntervalSince1970: 0)
    )
    #expect(SessionCostTranscriptResolver.source(
        provider: .codex,
        agentSessionID: "thread-a",
        importedHistory: [imported]
    )?.transcriptURL == url)
    #expect(SessionCostTranscriptResolver.source(
        provider: .claude,
        agentSessionID: "thread-a",
        importedHistory: [imported]
    ) == nil)
    #expect(SessionCostTranscriptResolver.source(
        provider: .deepseek,
        agentSessionID: "thread-a",
        importedHistory: [imported]
    ) == nil)
}

@Test func codexCacheWriteWithoutTTLFailsClosed() throws {
    let url = try temporaryTranscript([
        #"{"timestamp":"2026-09-25T01:19:02.000Z","type":"turn_context","payload":{"turn_id":"turn-a","model":"gpt-6.1-sol"}}"#,
        #"{"timestamp":"2026-09-25T01:19:07.000Z","type":"token_usage_record","payload":{"turn_id":"turn-a","response_id":"response-a","usage":{"input_tokens":1000,"cached_input_tokens":200,"cache_write_input_tokens":100,"output_tokens":50}}}"#
    ])
    let transcript = try #require(SessionTranscriptCostReader.read(
        url: url,
        provider: .codex,
        startingAt: 0,
        previous: nil
    ))
    #expect(transcript.transcript.records[0].usage.uncachedInput == 700)
    #expect(SessionCostCalculator.estimate(transcript: transcript.transcript)
        == .unavailable(.incompletePricing))
}

@Test func codexFastModeUsesDoubleRateForPriorityAndFastAliases() throws {
    let url = try temporaryTranscript([
        #"{"timestamp":"2026-09-25T01:19:01.000Z","type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"model":"gpt-6.1-sol","service_tier":"priority"}}}"#,
        #"{"timestamp":"2026-09-25T01:19:02.000Z","type":"turn_context","payload":{"turn_id":"turn-a","model":"gpt-6.1-sol"}}"#,
        #"{"timestamp":"2026-09-25T01:19:07.000Z","type":"token_usage_record","payload":{"turn_id":"turn-a","response_id":"response-a","usage":{"input_tokens":1000,"cached_input_tokens":0,"output_tokens":50}}}"#
    ])
    let transcript = try #require(SessionTranscriptCostReader.read(
        url: url,
        provider: .codex,
        startingAt: 0,
        previous: nil
    ))
    #expect(transcript.transcript.records[0].serviceTier == "priority")
    #expect(SessionCostCalculator.estimate(transcript: transcript.transcript)
        == .complete(amount: Decimal(string: "0.005")!, tint: .codex))
    #expect(estimate([
        record("gpt-6.1-sol", uncachedInput: 1_000_000, serviceTier: "fast")
    ]) == .complete(amount: 8, tint: .codex))
}

@Test func fastModeDoesNotApplyToDeepSeekOrClaudeRows() {
    #expect(estimate([
        record("deepseek-v4.1-flash", uncachedInput: 1_000_000, serviceTier: "priority")
    ]) == .unavailable(.unpricedPricingModifier))
    #expect(estimate([
        record("claude-opus-5-5", uncachedInput: 1_000_000, serviceTier: "priority")
    ]) == .unavailable(.unpricedPricingModifier))
}

@Test func claudeGeographyAndSpeedModifiersFailClosed() {
    #expect(estimate([record("claude-opus-5-5", uncachedInput: 1_000_000, inferenceGeography: "global")])
        == .complete(amount: 4, tint: .claude))
    #expect(estimate([record("claude-opus-5-5", uncachedInput: 1_000_000, inferenceGeography: "not_available")])
        == .complete(amount: 4, tint: .claude))
    #expect(estimate([record("claude-opus-5-5", uncachedInput: 1_000_000, inferenceGeography: "us")])
        == .complete(amount: Decimal(string: "4.4")!, tint: .claude))
    #expect(estimate([record("claude-opus-5-5", uncachedInput: 1_000_000, serviceTier: "priority")])
        == .unavailable(.unpricedPricingModifier))
    #expect(estimate([record("claude-opus-5-5", uncachedInput: 1_000_000, speed: "fast")])
        == .unavailable(.unpricedPricingModifier))
}

@Test func claudeUSGeographyMultipliesCacheWritesAndReads() {
    let usage = record(
        "claude-opus-5-5",
        uncachedInput: 1_000_000,
        cachedInput: 1_000_000,
        cacheWrite: 2_000_000,
        output: 1_000_000,
        inferenceGeography: "us"
    )
    let withSplit = SessionCostUsageRecord(
        modelID: usage.modelID,
        timestamp: usage.timestamp,
        usage: usage.usage,
        inferenceGeography: usage.inferenceGeography,
        cacheWrite5m: 1_000_000,
        cacheWrite1h: 1_000_000
    )
    #expect(estimate([withSplit]) == .complete(
        amount: Decimal(string: "40.92")!,
        tint: .claude
    ))
}

@Test func openAILongContextUsesExplicitLongRates() {
    let short = record("gpt-5.5", uncachedInput: 272_000)
    let long = record("gpt-5.5", uncachedInput: 272_001)
    #expect(estimate([short]) == .complete(amount: Decimal(string: "1.36")!, tint: .codex))
    #expect(estimate([long]) == .complete(
        amount: Decimal(string: "2.72001")!,
        tint: .codex
    ))
}

@Test func openAIPricingIncludesGPT54AndCorrectLongContextOutputRates() {
    let gpt54 = record("gpt-5.4", uncachedInput: 1_000_000)
    #expect(estimate([gpt54]) == .complete(
        amount: Decimal(string: "5")!,
        tint: .codex
    ))
    #expect(SessionCostCatalog.current.entry(for: record("gpt-5.4", uncachedInput: 1))?.rate == SessionCostRate(
        input: Decimal(string: "2.50")!,
        cachedInput: Decimal(string: "0.25")!,
        output: Decimal(string: "15.00")!
    ))

    for (modelID, outputRate) in [
        ("gpt-6.1-sol", Decimal(string: "15.00")!),
        ("gpt-6-sol", Decimal(string: "15.00")!)
    ] {
        let long = record(modelID, uncachedInput: 272_001)
        #expect(SessionCostCatalog.current.entry(for: long)?.rate.output == outputRate)
    }
}

@Test func openAIFastModeUsesPublishedPerModelPremium() {
    // GPT-6.1 is 2x Standard; GPT-5.5 publishes a 2.5x Fast card.
    #expect(estimate([
        record("gpt-6.1-sol", uncachedInput: 1_000_000, serviceTier: "fast")
    ]) == .complete(amount: 8, tint: .codex))
    #expect(estimate([
        record("gpt-5.5", uncachedInput: 100_000, serviceTier: "fast")
    ]) == .complete(amount: Decimal(string: "1.25")!, tint: .codex))
    // Fast mode publishes no long-context card for GPT-5.5/GPT-5.4, so a
    // request above 272K prompt tokens stays hidden instead of using 2x.
    #expect(estimate([
        record("gpt-5.5", uncachedInput: 300_000, serviceTier: "fast")
    ]) == .unavailable(.unpricedPricingModifier))
    #expect(estimate([
        record("gpt-5.4", uncachedInput: 300_000, serviceTier: "fast")
    ]) == .unavailable(.unpricedPricingModifier))
    #expect(estimate([
        record("gpt-5.4", uncachedInput: 100_000, serviceTier: "fast")
    ]) == .complete(amount: Decimal(string: "0.5")!, tint: .codex))
    // gpt-5.3-codex publishes a 2x Fast card; models without one must not be
    // guessed at 2x.
    #expect(estimate([
        record("gpt-5.3-codex", uncachedInput: 100_000, serviceTier: "fast")
    ]) == .complete(amount: Decimal(string: "0.35")!, tint: .codex))
    #expect(estimate([
        record("gpt-5.2", uncachedInput: 100_000, serviceTier: "fast")
    ]) == .complete(amount: Decimal(string: "0.35")!, tint: .codex))
    #expect(estimate([
        record("gpt-5.6-cyber", uncachedInput: 100_000, serviceTier: "fast")
    ]) == .unavailable(.unpricedPricingModifier))
}

@Test func providerQualifiedModelIDsUseTheSameDatedRate() {
    let qualified = record("openai/gpt-5.5", uncachedInput: 1_000_000)
    let bare = record("gpt-5.5", uncachedInput: 1_000_000)
    #expect(estimate([qualified]) == estimate([bare]))
    #expect(estimate([qualified]) == .complete(amount: 10, tint: .codex))
}

@Test func haikuLongPromptUsesExplicitHigherRates() {
    let short = record("claude-haiku-5-5", uncachedInput: 100_000)
    let long = record("claude-haiku-5-5", uncachedInput: 100_001)
    #expect(estimate([short]) == .complete(amount: Decimal(string: "0.01")!, tint: .claude))
    #expect(estimate([long]) == .complete(
        amount: Decimal(string: "0.0500005")!,
        tint: .claude
    ))
}

@Test func deepSeekLegacyAliasPricesAsFlashAndCarriesModelTint() {
    let timestamp = date("2026-10-24T12:00:00Z") // Saturday, off-peak.
    for modelID in ["deepseek-v4.1-flash", "deepseek-v4-flash"] {
        let flash = record(
            modelID,
            uncachedInput: 1_000_000,
            timestamp: timestamp
        )
        #expect(estimate([flash]) == .complete(
            amount: Decimal(string: "0.15")!,
            tint: .deepSeek
        ))
        #expect(SessionCostCatalog.current.entry(for: flash)?.rate.output == Decimal(string: "0.60"))
    }
}

@Test func deepSeekPeakBoundariesUseUTCWeekdays() {
    let catalog = SessionCostCatalog.current
    #expect(catalog.entry(for: record("deepseek-flash", uncachedInput: 1, timestamp: date("2026-10-26T00:59:59Z")))?.isPeakRate == false)
    #expect(catalog.entry(for: record("deepseek-flash", uncachedInput: 1, timestamp: date("2026-10-26T01:00:00Z")))?.isPeakRate == true)
    #expect(catalog.entry(for: record("deepseek-flash", uncachedInput: 1, timestamp: date("2026-10-26T03:59:59Z")))?.isPeakRate == true)
    #expect(catalog.entry(for: record("deepseek-flash", uncachedInput: 1, timestamp: date("2026-10-26T04:00:00Z")))?.isPeakRate == false)
    #expect(catalog.entry(for: record("deepseek-flash", uncachedInput: 1, timestamp: date("2026-10-26T06:00:00Z")))?.isPeakRate == true)
    #expect(catalog.entry(for: record("deepseek-flash", uncachedInput: 1, timestamp: date("2026-10-26T10:00:00Z")))?.isPeakRate == false)
    #expect(catalog.entry(for: record("deepseek-flash", uncachedInput: 1, timestamp: date("2026-10-24T01:00:00Z")))?.isPeakRate == false)
}

@Test func claudeCacheWriteWithoutExplicitTTLFailsClosed() {
    let cacheWrite = record("claude-opus-5-5", cacheWrite: 100)
    #expect(estimate([cacheWrite]) == .unavailable(.incompletePricing))
}

@Test func estimateRequiresKnownTimestampAndCompleteTranscript() {
    var unknownTime = record("gpt-6.1-sol", uncachedInput: 100)
    unknownTime = SessionCostUsageRecord(
        modelID: unknownTime.modelID,
        timestamp: unknownTime.timestamp,
        timestampIsKnown: false,
        usage: unknownTime.usage
    )
    #expect(estimate([unknownTime]) == .unavailable(.unknownTimestamp))
    #expect(SessionCostCalculator.estimate(transcript: SessionCostTranscript(
        records: [record("gpt-6.1-sol", uncachedInput: 100)],
        hasUnpricedUsage: true
    )) == .unavailable(.incompletePricing))
}

private extension String {
    func append(to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(self.utf8))
    }
}
