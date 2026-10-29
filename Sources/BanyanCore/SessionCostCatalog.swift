import Foundation

/// Local, dated API-price catalog. Rates are USD per one million tokens.
public struct SessionCostRate: Sendable, Equatable {
    public let input: Decimal
    public let cachedInput: Decimal
    public let output: Decimal
    /// Claude records the cache-write lifetime explicitly. OpenAI records only
    /// `cache_write_input_tokens`, without the 30m/12h TTL, so OpenAI rows leave
    /// both write rates nil and the calculator fails closed for nonzero writes.
    public let cacheWrite5m: Decimal?
    public let cacheWrite1h: Decimal?

    public init(
        input: Decimal,
        cachedInput: Decimal,
        output: Decimal,
        cacheWrite5m: Decimal? = nil,
        cacheWrite1h: Decimal? = nil
    ) {
        self.input = input
        self.cachedInput = cachedInput
        self.output = output
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
    }
}

public struct SessionCostCatalogEntry: Sendable, Equatable {
    public let provider: SessionCostProvider
    public let aliases: [String]
    public let rate: SessionCostRate
    public let tint: SessionCostTint
    /// Inclusive prompt-token bounds. OpenAI's short/long boundary is 272K;
    /// Claude Haiku 5.5's is 100K. Other rows leave these unbounded.
    public let minimumPromptTokens: Int
    public let maximumPromptTokens: Int?
    public let effectiveFrom: Date
    public let source: String
    /// DeepSeek publishes peak and off-peak rates. `false` means off-peak.
    public let isPeakRate: Bool
    /// Fast mode is a separate published rate card rather than a uniform tier.
    /// Rows that publish one list its multiplier; `nil` means no Fast rate is
    /// published for that model/context length, so a `fast`/`priority` row must
    /// fail closed instead of guessing.
    public let fastModeMultiplier: Decimal?

    public init(
        provider: SessionCostProvider,
        aliases: [String],
        rate: SessionCostRate,
        tint: SessionCostTint,
        minimumPromptTokens: Int = 0,
        maximumPromptTokens: Int? = nil,
        effectiveFrom: Date,
        source: String,
        isPeakRate: Bool = false,
        fastModeMultiplier: Decimal? = nil
    ) {
        self.provider = provider
        self.aliases = aliases.map(Self.normalize)
        self.rate = rate
        self.tint = tint
        self.minimumPromptTokens = minimumPromptTokens
        self.maximumPromptTokens = maximumPromptTokens
        self.effectiveFrom = effectiveFrom
        self.source = source
        self.isPeakRate = isPeakRate
        self.fastModeMultiplier = fastModeMultiplier
    }

    static func normalize(_ modelID: String) -> String {
        modelID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "[1m]", with: "")
    }
}

public struct SessionCostCatalog: Sendable {
    public let entries: [SessionCostCatalogEntry]

    public init(entries: [SessionCostCatalogEntry]) {
        self.entries = entries
    }

    public func entry(for record: SessionCostUsageRecord) -> SessionCostCatalogEntry? {
        let normalized = SessionCostCatalogEntry.normalize(record.modelID)
        let promptTokens = record.usage.promptTokens
        let isPeak = Self.isDeepSeekModel(normalized)
            && Self.isDeepSeekPeak(at: record.timestamp)

        return entries
            .filter { entry in
                Self.matchesAlias(normalized, aliases: entry.aliases)
                    && entry.effectiveFrom <= record.timestamp
                    && promptTokens >= entry.minimumPromptTokens
                    && (entry.maximumPromptTokens.map { promptTokens <= $0 } ?? true)
                    && entry.isPeakRate == isPeak
            }
            .max { lhs, rhs in
                if lhs.minimumPromptTokens != rhs.minimumPromptTokens {
                    return lhs.minimumPromptTokens < rhs.minimumPromptTokens
                }
                return lhs.effectiveFrom < rhs.effectiveFrom
            }
    }

    private static func matchesAlias(_ modelID: String, aliases: [String]) -> Bool {
        aliases.contains(modelID)
            || modelID
                .split(separator: "/")
                .contains(where: { aliases.contains(String($0)) })
    }

    public static func isDeepSeekModel(_ modelID: String) -> Bool {
        SessionCostCatalogEntry.normalize(modelID).contains("deepseek")
    }

    /// DeepSeek publishes these windows in UTC, Monday-Friday. Chinese public
    /// holidays are a known limitation: they are treated as normal weekdays,
    /// which can over-estimate a weekday peak-window session on a holiday.
    public static func isDeepSeekPeak(at date: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let weekday = calendar.component(.weekday, from: date)
        guard (2...6).contains(weekday) else { return false }
        let hour = calendar.component(.hour, from: date)
        return (1..<4).contains(hour) || (6..<10).contains(hour)
    }

    public static let current: SessionCostCatalog = {
        let from = Date(timeIntervalSince1970: 1_735_689_600) // 2025-01-01Z
        let openAISource = "https://developers.openai.com/api/docs/pricing"
        let anthropicSource = "https://platform.claude.com/docs/en/about-claude/pricing"
        let deepSeekSource = "https://api-docs.deepseek.com/quick_start/pricing/"
        let openAIShortMaximum = 272_000
        let haikuShortMaximum = 100_000

        func openAI(
            _ aliases: [String],
            input: String,
            cached: String,
            output: String,
            minimumPromptTokens: Int = 0,
            maximumPromptTokens: Int? = openAIShortMaximum,
            fastModeMultiplier: Decimal?
        ) -> SessionCostCatalogEntry {
            SessionCostCatalogEntry(
                provider: .codex,
                aliases: aliases,
                rate: SessionCostRate(
                    input: Decimal(string: input)!,
                    cachedInput: Decimal(string: cached)!,
                    output: Decimal(string: output)!
                ),
                tint: .codex,
                minimumPromptTokens: minimumPromptTokens,
                maximumPromptTokens: maximumPromptTokens,
                effectiveFrom: from,
                source: openAISource,
                fastModeMultiplier: fastModeMultiplier
            )
        }

        func openAIShortAndLong(
            _ aliases: [String],
            input: String,
            cached: String,
            output: String,
            longInput: String,
            longCached: String,
            longOutput: String,
            fastModeMultiplier: Decimal? = 2,
            longFastModeMultiplier: Decimal? = 2
        ) -> [SessionCostCatalogEntry] {
            [
                openAI(
                    aliases,
                    input: input,
                    cached: cached,
                    output: output,
                    fastModeMultiplier: fastModeMultiplier
                ),
                openAI(
                    aliases,
                    input: longInput,
                    cached: longCached,
                    output: longOutput,
                    minimumPromptTokens: openAIShortMaximum + 1,
                    maximumPromptTokens: nil,
                    fastModeMultiplier: longFastModeMultiplier
                )
            ]
        }

        func claude(
            _ aliases: [String],
            input: String,
            output: String,
            write5m: String,
            write1h: String,
            cached: String,
            tint: SessionCostTint = .claude,
            minimumPromptTokens: Int = 0,
            maximumPromptTokens: Int? = nil
        ) -> SessionCostCatalogEntry {
            SessionCostCatalogEntry(
                provider: .claude,
                aliases: aliases,
                rate: SessionCostRate(
                    input: Decimal(string: input)!,
                    cachedInput: Decimal(string: cached)!,
                    output: Decimal(string: output)!,
                    cacheWrite5m: Decimal(string: write5m)!,
                    cacheWrite1h: Decimal(string: write1h)!
                ),
                tint: tint,
                minimumPromptTokens: minimumPromptTokens,
                maximumPromptTokens: maximumPromptTokens,
                effectiveFrom: from,
                source: anthropicSource
            )
        }

        func deepSeek(
            _ aliases: [String],
            peak: Bool,
            input: String,
            cached: String,
            output: String
        ) -> SessionCostCatalogEntry {
            SessionCostCatalogEntry(
                provider: .codex,
                aliases: aliases,
                rate: SessionCostRate(
                    input: Decimal(string: input)!,
                    cachedInput: Decimal(string: cached)!,
                    output: Decimal(string: output)!
                ),
                tint: .deepSeek,
                effectiveFrom: from,
                source: deepSeekSource,
                isPeakRate: peak
            )
        }

        let openAIRows =
            openAIShortAndLong(
                ["gpt-6.1-sol"],
                input: "2.00", cached: "0.10", output: "10.00",
                longInput: "4.00", longCached: "0.20", longOutput: "15.00"
            ) + openAIShortAndLong(
                ["gpt-6.1-terra"],
                input: "1.00", cached: "0.05", output: "5.00",
                longInput: "2.00", longCached: "0.10", longOutput: "7.50"
            ) + openAIShortAndLong(
                ["gpt-6-luna"],
                input: "0.10", cached: "0.01", output: "0.50",
                longInput: "0.20", longCached: "0.02", longOutput: "0.75"
            ) + openAIShortAndLong(
                ["gpt-6-astra"],
                input: "10.00", cached: "1.00", output: "50.00",
                longInput: "20.00", longCached: "2.00", longOutput: "75.00"
            ) + openAIShortAndLong(
                ["gpt-6-sol"],
                input: "2.00", cached: "0.20", output: "10.00",
                longInput: "4.00", longCached: "0.40", longOutput: "15.00"
            ) + openAIShortAndLong(
                ["gpt-5.6-sol"],
                input: "4.00", cached: "0.40", output: "20.00",
                longInput: "8.00", longCached: "0.80", longOutput: "30.00"
            ) + openAIShortAndLong(
                ["gpt-5.6-terra"],
                input: "2.00", cached: "0.20", output: "12.00",
                longInput: "4.00", longCached: "0.40", longOutput: "18.00"
            ) + openAIShortAndLong(
                ["gpt-5.6-luna"],
                input: "0.20", cached: "0.02", output: "1.20",
                longInput: "0.40", longCached: "0.04", longOutput: "1.80"
            ) + openAIShortAndLong(
                ["gpt-5.5"],
                input: "5.00", cached: "0.50", output: "30.00",
                longInput: "10.00", longCached: "1.00", longOutput: "45.00",
                // Fast mode publishes only a short-context card for GPT-5.5, at
                // 2.5x rather than the 2x used by GPT-6 models.
                fastModeMultiplier: Decimal(string: "2.5")!,
                longFastModeMultiplier: nil
            ) + openAIShortAndLong(
                ["gpt-5.4"],
                input: "2.50", cached: "0.25", output: "15.00",
                longInput: "5.00", longCached: "0.50", longOutput: "22.50",
                longFastModeMultiplier: nil
            ) + [
                // gpt-5.3-codex and gpt-5.2 publish 2x Fast cards. The cyber
                // row publishes none, so it must fail closed on a fast tier.
                openAI(
                    ["gpt-5.6-cyber"],
                    input: "12.50", cached: "1.25", output: "75.00",
                    fastModeMultiplier: nil
                ),
                openAI(
                    ["gpt-5.3-codex"],
                    input: "1.75", cached: "0.175", output: "14.00",
                    fastModeMultiplier: 2
                ),
                openAI(
                    ["gpt-5.2"],
                    input: "1.75", cached: "0.175", output: "14.00",
                    fastModeMultiplier: 2
                )
            ]

        let claudeRows = [
            claude(["claude-fable-5-1", "claude-fable-5.1"], input: "10.00", output: "50.00", write5m: "12.50", write1h: "20.00", cached: "0.25"),
            claude(["claude-fable-5", "claude-fable-5.0"], input: "10.00", output: "50.00", write5m: "12.50", write1h: "20.00", cached: "1.00"),
            claude(["claude-mythos-5-1", "claude-mythos-5.1"], input: "10.00", output: "50.00", write5m: "12.50", write1h: "20.00", cached: "0.25"),
            claude(["claude-mythos-5", "claude-mythos-5.0"], input: "10.00", output: "50.00", write5m: "12.50", write1h: "20.00", cached: "1.00"),
            claude(["claude-opus-5-5", "claude-opus-5.5"], input: "4.00", output: "20.00", write5m: "5.00", write1h: "8.00", cached: "0.20"),
            claude(["claude-opus-5"], input: "5.00", output: "25.00", write5m: "6.25", write1h: "10.00", cached: "0.50"),
            claude(["claude-opus-4-8", "claude-opus-4.8", "claude-opus-4-7", "claude-opus-4.7", "claude-opus-4-6", "claude-opus-4.6", "claude-opus-4-5", "claude-opus-4.5"], input: "5.00", output: "25.00", write5m: "6.25", write1h: "10.00", cached: "0.50"),
            claude(["claude-opus-4-1", "claude-opus-4.1", "claude-opus-4"], input: "15.00", output: "75.00", write5m: "18.75", write1h: "30.00", cached: "1.50"),
            claude(["claude-sonnet-5-5", "claude-sonnet-5.5"], input: "2.00", output: "10.00", write5m: "2.50", write1h: "4.00", cached: "0.10"),
            claude(["claude-sonnet-5"], input: "2.00", output: "10.00", write5m: "2.50", write1h: "4.00", cached: "0.20"),
            claude(["claude-sonnet-4-6", "claude-sonnet-4.6", "claude-sonnet-4-5", "claude-sonnet-4.5", "claude-sonnet-4"], input: "3.00", output: "15.00", write5m: "3.75", write1h: "6.00", cached: "0.30"),
            claude(
                ["claude-haiku-5-5", "claude-haiku-5.5"],
                input: "0.10", output: "0.50", write5m: "0.125", write1h: "0.20", cached: "0.01",
                maximumPromptTokens: haikuShortMaximum
            ),
            claude(
                ["claude-haiku-5-5", "claude-haiku-5.5"],
                input: "0.50", output: "2.50", write5m: "0.625", write1h: "1.00", cached: "0.05",
                minimumPromptTokens: haikuShortMaximum + 1
            ),
            claude(["claude-haiku-4-5", "claude-haiku-4.5"], input: "1.00", output: "5.00", write5m: "1.25", write1h: "2.00", cached: "0.10"),
            claude(["claude-haiku-3-5", "claude-haiku-3.5"], input: "0.80", output: "4.00", write5m: "1.00", write1h: "1.60", cached: "0.08")
        ]

        let deepSeekAliases = [
            "deepseek-flash",
            "deepseek-v4.1-flash",
            "deepseek-v4-flash",
            "deepseek-v4-flash-vision-exp"
        ]
        let deepSeekRows = [
            deepSeek(deepSeekAliases, peak: false, input: "0.15", cached: "0.003", output: "0.60"),
            deepSeek(deepSeekAliases, peak: true, input: "0.30", cached: "0.006", output: "1.20"),
            deepSeek(["deepseek-v4-pro"], peak: false, input: "0.66", cached: "0.022", output: "1.98"),
            deepSeek(["deepseek-v4-pro"], peak: true, input: "1.32", cached: "0.044", output: "3.96")
        ]

        return SessionCostCatalog(entries: openAIRows + claudeRows + deepSeekRows)
    }()
}

public enum SessionCostCalculator {
    public static func estimate(
        transcript: SessionCostTranscript,
        catalog: SessionCostCatalog = .current
    ) -> SessionCostEstimate {
        guard !transcript.records.isEmpty else {
            return .unavailable(.noUsage)
        }
        var total = Decimal.zero
        var tint: SessionCostTint?
        for record in transcript.records {
            guard record.timestampIsKnown else {
                return .unavailable(.unknownTimestamp)
            }
            guard hasSupportedPricingModifiers(record) else {
                return .unavailable(.unpricedPricingModifier)
            }
            guard let entry = catalog.entry(for: record) else {
                return .unavailable(.unknownModel(record.modelID))
            }
            guard supportsPricingModifiers(record, entry: entry) else {
                return .unavailable(.unpricedPricingModifier)
            }
            guard let recordCost = price(record, entry: entry) else {
                return .unavailable(.incompletePricing)
            }
            total += recordCost
            if let existingTint = tint, existingTint != entry.tint {
                tint = .mixed
            } else {
                tint = entry.tint
            }
        }
        guard !transcript.hasUnpricedUsage, let tint else {
            return .unavailable(.incompletePricing)
        }
        return .complete(amount: total, tint: tint)
    }

    static func hasSupportedPricingModifiers(_ record: SessionCostUsageRecord) -> Bool {
        let tier = normalized(record.serviceTier)
        guard [nil, "", "default", "standard", "priority", "fast"].contains(tier) else {
            return false
        }

        let geography = normalized(record.inferenceGeography)
        guard [nil, "", "global", "not_available", "us"].contains(geography) else { return false }

        let speed = normalized(record.speed)
        return [nil, "", "standard"].contains(speed)
    }

    static func supportsPricingModifiers(
        _ record: SessionCostUsageRecord,
        entry: SessionCostCatalogEntry
    ) -> Bool {
        guard hasSupportedPricingModifiers(record) else { return false }
        let usesFastMode = ["priority", "fast"].contains(normalized(record.serviceTier))
        guard usesFastMode else { return true }
        // Fast mode ("priority" in older logs) is an OpenAI-only tier with a
        // per-model premium. DeepSeek usage in a Codex transcript and Claude
        // usage never use it; models without a published Fast rate fail closed.
        return entry.provider == .codex
            && !SessionCostCatalog.isDeepSeekModel(record.modelID)
            && entry.fastModeMultiplier != nil
    }

    private static func normalized(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public static func price(
        _ record: SessionCostUsageRecord,
        entry: SessionCostCatalogEntry
    ) -> Decimal? {
        guard supportsPricingModifiers(record, entry: entry) else { return nil }
        let tier = normalized(record.serviceTier)
        let usesFastMode = ["priority", "fast"].contains(tier)
        let rate = entry.rate
        let million = Decimal(1_000_000)
        var total = Decimal(record.usage.uncachedInput) * rate.input / million
        total += Decimal(record.usage.cachedInput) * rate.cachedInput / million
        total += Decimal(record.usage.output) * rate.output / million

        if record.usage.cacheWrite > 0 {
            switch entry.provider {
            case .claude:
                let split = record.cacheWrite5m + record.cacheWrite1h
                guard split == record.usage.cacheWrite,
                      let rate5m = rate.cacheWrite5m,
                      let rate1h = rate.cacheWrite1h
                else { return nil }
                total += Decimal(record.cacheWrite5m) * rate5m / million
                total += Decimal(record.cacheWrite1h) * rate1h / million
            case .codex:
                // Codex does not record whether an OpenAI cache write has the
                // 30m or 12h TTL, so a nonzero write cannot be priced
                // unambiguously.
                return nil
            }
        }

        // Claude prices US-only inference at 1.1x for Claude 4.6 and later.
        // Every cataloged Claude model that can emit `us` is in that range.
        if entry.provider == .claude,
           normalized(record.inferenceGeography) == "us" {
            total *= Decimal(string: "1.1")!
        }
        if entry.provider == .codex, usesFastMode {
            guard let multiplier = entry.fastModeMultiplier else { return nil }
            total *= multiplier
        }
        return total
    }
}
