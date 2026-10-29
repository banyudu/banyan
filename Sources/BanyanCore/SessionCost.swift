import Foundation

public enum SessionCostProvider: String, Sendable, Equatable {
    case codex
    case claude
}

public enum SessionCostTint: String, Sendable, Equatable {
    case claude
    case codex
    case deepSeek
    case mixed
}

public struct SessionTokenUsage: Sendable, Equatable {
    public var uncachedInput: Int
    public var cachedInput: Int
    public var cacheWrite: Int
    public var output: Int

    public init(uncachedInput: Int = 0, cachedInput: Int = 0, cacheWrite: Int = 0, output: Int = 0) {
        self.uncachedInput = max(0, uncachedInput)
        self.cachedInput = max(0, cachedInput)
        self.cacheWrite = max(0, cacheWrite)
        self.output = max(0, output)
    }

    public var totalTokens: Int {
        uncachedInput + cachedInput + cacheWrite + output
    }

    /// Everything submitted as prompt context. Threshold pricing applies to
    /// this value; output and reasoning are not part of it.
    public var promptTokens: Int {
        uncachedInput + cachedInput + cacheWrite
    }

    public static func + (lhs: Self, rhs: Self) -> Self {
        Self(
            uncachedInput: lhs.uncachedInput + rhs.uncachedInput,
            cachedInput: lhs.cachedInput + rhs.cachedInput,
            cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
            output: lhs.output + rhs.output
        )
    }
}

public struct SessionCostUsageRecord: Sendable, Equatable {
    public let modelID: String
    public let timestamp: Date
    /// When false, time-of-use and effective-date pricing are not safe.
    public let timestampIsKnown: Bool
    public let usage: SessionTokenUsage
    /// Pricing modifier reported by the provider. `nil` and standard/default
    /// values use the catalog's Standard rates. OpenAI's `priority` and `fast`
    /// aliases use the model's published Fast-mode rate; other values fail
    /// closed.
    public let serviceTier: String?
    /// Claude's `inference_geo`. `nil`, empty, `global`, and `not_available`
    /// use standard rates; other values are unpriced in v1.
    public let inferenceGeography: String?
    /// Claude's `speed` field. `nil` and `standard` use standard pricing;
    /// Fast-mode values are intentionally unpriced in v1.
    public let speed: String?
    /// Cache writes whose duration was explicitly reported. When present these
    /// are already included in `usage.cacheWrite`.
    public let cacheWrite5m: Int
    public let cacheWrite1h: Int

    public init(
        modelID: String,
        timestamp: Date,
        timestampIsKnown: Bool = true,
        usage: SessionTokenUsage,
        serviceTier: String? = nil,
        inferenceGeography: String? = nil,
        speed: String? = nil,
        cacheWrite5m: Int = 0,
        cacheWrite1h: Int = 0
    ) {
        self.modelID = modelID
        self.timestamp = timestamp
        self.timestampIsKnown = timestampIsKnown
        self.usage = usage
        self.serviceTier = serviceTier
        self.inferenceGeography = inferenceGeography
        self.speed = speed
        self.cacheWrite5m = max(0, cacheWrite5m)
        self.cacheWrite1h = max(0, cacheWrite1h)
    }
}

public struct SessionCostTranscript: Sendable, Equatable {
    public let records: [SessionCostUsageRecord]
    public let hasUnpricedUsage: Bool
    /// Parser state needed to continue from the offset after the last complete
    /// line. It contains only model/deduplication metadata, never transcript text.
    public let continuation: SessionCostReaderContinuation?

    public init(
        records: [SessionCostUsageRecord],
        hasUnpricedUsage: Bool = false,
        continuation: SessionCostReaderContinuation? = nil
    ) {
        self.records = records
        self.hasUnpricedUsage = hasUnpricedUsage
        self.continuation = continuation
    }
}

public struct SessionCostReaderContinuation: Sendable, Equatable {
    public let modelsByTurnID: [String: String]
    public let lastModelID: String?
    public let seenCodexResponses: Set<String>
    public let seenClaudeMessages: Set<String>
    public let codexInput: Int
    public let codexCachedInput: Int
    public let codexCacheWrite: Int
    public let codexOutput: Int
    public let codexHasRecords: Bool
    public let codexServiceTier: String?
    public let cumulativeRecords: [SessionCostUsageRecord]

    public init(
        modelsByTurnID: [String: String] = [:],
        lastModelID: String? = nil,
        seenCodexResponses: Set<String> = [],
        seenClaudeMessages: Set<String> = [],
        codexInput: Int = 0,
        codexCachedInput: Int = 0,
        codexCacheWrite: Int = 0,
        codexOutput: Int = 0,
        codexHasRecords: Bool = false,
        codexServiceTier: String? = nil,
        cumulativeRecords: [SessionCostUsageRecord] = []
    ) {
        self.modelsByTurnID = modelsByTurnID
        self.lastModelID = lastModelID
        self.seenCodexResponses = seenCodexResponses
        self.seenClaudeMessages = seenClaudeMessages
        self.codexInput = codexInput
        self.codexCachedInput = codexCachedInput
        self.codexCacheWrite = codexCacheWrite
        self.codexOutput = codexOutput
        self.codexHasRecords = codexHasRecords
        self.codexServiceTier = codexServiceTier
        self.cumulativeRecords = cumulativeRecords
    }
}

public enum SessionCostUnavailableReason: Sendable, Equatable {
    case unreadableTranscript
    case noUsage
    case unknownModel(String)
    case incompletePricing
    case unpricedPricingModifier
    case unknownTimestamp
}

public enum SessionCostEstimate: Sendable, Equatable {
    case complete(amount: Decimal, tint: SessionCostTint)
    case unavailable(SessionCostUnavailableReason)

    public var amount: Decimal? {
        guard case let .complete(amount, _) = self else { return nil }
        return amount
    }

    public var tint: SessionCostTint? {
        guard case let .complete(_, tint) = self else { return nil }
        return tint
    }
}

/// A coarse, non-monetary cost state for compact sidebar surfaces. Exact
/// amounts remain hover-only; this only answers which severity of persistent
/// warning a complete estimate has crossed.
public enum SessionCostTier: Sendable, Equatable {
    case standard
    case expensive
    case critical

    public static let expensiveThreshold: Decimal = 20
    public static let criticalThreshold: Decimal = 100

    public init(estimate: SessionCostEstimate?) {
        guard case let .complete(amount, _) = estimate else {
            self = .standard
            return
        }
        if amount > Self.criticalThreshold {
            self = .critical
        } else if amount >= Self.expensiveThreshold {
            self = .expensive
        } else {
            self = .standard
        }
    }

}

public struct SessionCostDisplay: Sendable, Equatable {
    public let amount: Decimal

    public init(amount: Decimal) {
        self.amount = amount
    }

    public var text: String {
        if amount <= 0 {
            return "<$0.01"
        }
        if amount < Decimal(string: "0.01")! {
            return "<$0.01"
        }
        if amount < 1 {
            return "$" + Self.format(amount, fractionDigits: 2)
        }
        if amount < 100 {
            return "$" + Self.format(amount, fractionDigits: 1)
        }
        return "$" + Self.format(amount, fractionDigits: 0)
    }

    private static func format(_ value: Decimal, fractionDigits: Int) -> String {
        // Corelibs Foundation may retain excess NSDecimalNumber precision.
        // Round the decimal before formatting so every platform uses the same scale.
        var source = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &source, fractionDigits, .plain)
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ""
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        formatter.roundingMode = .halfUp
        return formatter.string(from: rounded as NSDecimalNumber) ?? "0"
    }
}
