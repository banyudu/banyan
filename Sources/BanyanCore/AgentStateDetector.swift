import Foundation

public struct AgentStateDetector: Sendable {
    public struct Result: Sendable {
        public let status: SessionStatus
        public let tone: SessionTone
    }

    private let rules: [DetectorRule]
    /// Patterns pre-lowercased as UTF-8, or nil when any of them is non-ASCII and
    /// must keep Unicode-correct case folding.
    private let asciiPatterns: [[[UInt8]]]?

    public init(rules: [DetectorRule]) {
        self.rules = rules
        self.asciiPatterns = Self.compileASCIIPatterns(rules)
    }

    /// This runs on the main thread for every PTY chunk, so it matches over UTF-8
    /// bytes rather than Strings. The obvious `text.lowercased().contains(pattern)`
    /// allocates a copy of every chunk and then pays Swift's grapheme-aware
    /// substring search for it, which measured ~2.4ms for a single 8.8KB agent
    /// frame — more main-thread time than repainting that frame costs.
    public func detect(in text: String) -> Result? {
        guard let asciiPatterns else {
            let lowercased = text.lowercased()
            for rule in rules where rule.matches(lowercased) {
                return Result(status: rule.status, tone: rule.tone)
            }
            return nil
        }
        let matched: Int? = text.utf8.withContiguousStorageIfAvailable { buffer in
            Self.firstMatchingRule(in: buffer, patterns: asciiPatterns)
        } ?? Array(text.utf8).withUnsafeBufferPointer { buffer in
            Self.firstMatchingRule(in: buffer, patterns: asciiPatterns)
        }
        guard let matched else { return nil }
        return Result(status: rules[matched].status, tone: rules[matched].tone)
    }

    /// Non-ASCII patterns keep the old path: only ASCII has a case mapping this can
    /// reproduce byte for byte.
    private static func compileASCIIPatterns(_ rules: [DetectorRule]) -> [[[UInt8]]]? {
        var compiled: [[[UInt8]]] = []
        compiled.reserveCapacity(rules.count)
        for rule in rules {
            var patterns: [[UInt8]] = []
            patterns.reserveCapacity(rule.patterns.count)
            for pattern in rule.patterns {
                let bytes = Array(pattern.utf8)
                guard bytes.allSatisfy({ $0 < 0x80 }), !bytes.isEmpty else { return nil }
                patterns.append(bytes.map(asciiLowercased))
            }
            compiled.append(patterns)
        }
        return compiled
    }

    @inline(__always)
    private static func asciiLowercased(_ byte: UInt8) -> UInt8 {
        // 'A'...'Z'
        (byte >= 0x41 && byte <= 0x5A) ? byte &+ 0x20 : byte
    }

    private static func firstMatchingRule(
        in haystack: UnsafeBufferPointer<UInt8>,
        patterns: [[[UInt8]]]
    ) -> Int? {
        for (index, rulePatterns) in patterns.enumerated() {
            for pattern in rulePatterns where containsASCII(haystack, pattern) {
                return index
            }
        }
        return nil
    }

    private static func containsASCII(
        _ haystack: UnsafeBufferPointer<UInt8>,
        _ needle: [UInt8]
    ) -> Bool {
        let needleCount = needle.count
        let haystackCount = haystack.count
        guard needleCount > 0, haystackCount >= needleCount else { return false }
        let first = needle[0]
        let limit = haystackCount - needleCount
        return needle.withUnsafeBufferPointer { needle -> Bool in
            var start = 0
            while start <= limit {
                if asciiLowercased(haystack[start]) == first {
                    var offset = 1
                    while offset < needleCount,
                          asciiLowercased(haystack[start + offset]) == needle[offset] {
                        offset += 1
                    }
                    if offset == needleCount { return true }
                }
                start += 1
            }
            return false
        }
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
