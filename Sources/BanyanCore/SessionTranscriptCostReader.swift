import CryptoKit
import Foundation

public final class SessionCostCache: @unchecked Sendable {
    private struct Signature: Equatable {
        let fileSize: UInt64
        let modifiedAt: Date
        let inode: UInt64?
        let provider: SessionCostProvider
    }

    private struct Entry {
        let signature: Signature
        let offset: UInt64
        let prefixDigest: Data
        let transcript: SessionCostTranscript
    }

    private let lock = NSLock()
    private var entries: [URL: Entry] = [:]

    public init() {}

    public func transcript(
        at url: URL,
        provider: SessionCostProvider,
        fileManager: FileManager = .default
    ) -> SessionCostTranscript? {
        let normalizedURL = url.standardizedFileURL
        guard let attributes = try? fileManager.attributesOfItem(atPath: normalizedURL.path),
              let sizeNumber = attributes[.size] as? NSNumber,
              let modifiedAt = attributes[.modificationDate] as? Date,
              (attributes[.type] as? FileAttributeType) == .typeRegular
        else {
            return nil
        }
        let fileSize = sizeNumber.uint64Value
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        let signature = Signature(
            fileSize: fileSize,
            modifiedAt: modifiedAt,
            inode: inode,
            provider: provider
        )

        lock.lock()
        let cached = entries[normalizedURL]
        lock.unlock()

        if let cached, cached.signature == signature {
            return cached.transcript
        }

        let previous = reusableEntry(
            cached,
            provider: provider,
            inode: signature.inode,
            fileSize: fileSize,
            at: normalizedURL
        )
        guard let parsed = SessionTranscriptCostReader.read(
            url: normalizedURL,
            provider: provider,
            startingAt: previous?.offset ?? 0,
            previous: previous?.transcript
        ) else {
            return nil
        }
        guard let prefixDigest = prefixDigest(
            at: normalizedURL,
            consumedOffset: parsed.consumedOffset
        ) else {
            return nil
        }

        lock.lock()
        entries[normalizedURL] = Entry(
            signature: signature,
            offset: parsed.consumedOffset,
            prefixDigest: prefixDigest,
            transcript: parsed.transcript
        )
        lock.unlock()
        return parsed.transcript
    }

    private func reusableEntry(
        _ cached: Entry?,
        provider: SessionCostProvider,
        inode: UInt64?,
        fileSize: UInt64,
        at url: URL
    ) -> Entry? {
        guard let cached,
              cached.signature.provider == provider,
              cached.signature.inode == inode,
              fileSize >= cached.offset,
              let currentDigest = prefixDigest(at: url, consumedOffset: cached.offset),
              currentDigest == cached.prefixDigest
        else {
            return nil
        }
        return cached
    }

    /// Hash the first 4 KiB of the already-consumed prefix. This detects the
    /// common in-place truncate-and-rewrite case without reading or retaining
    /// the whole transcript; it is a sampling check, not a full-content proof.
    private func prefixDigest(at url: URL, consumedOffset: UInt64) -> Data? {
        guard consumedOffset > 0 else { return Data(SHA256.hash(data: Data())) }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: 0)
            let length = Int(min(consumedOffset, 4_096))
            guard let prefix = try handle.read(upToCount: length), prefix.count == length else {
                return nil
            }
            return Data(SHA256.hash(data: prefix))
        } catch {
            return nil
        }
    }
}

public enum SessionTranscriptCostReader {
    struct Result {
        let transcript: SessionCostTranscript
        let consumedOffset: UInt64
    }

    static func read(
        url: URL,
        provider: SessionCostProvider,
        startingAt offset: UInt64,
        previous: SessionCostTranscript?
    ) -> Result? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        do {
            if offset > 0 {
                try handle.seek(toOffset: offset)
            }
            let data = try handle.readToEnd() ?? Data()
            guard !data.isEmpty || previous != nil else {
                return Result(transcript: SessionCostTranscript(records: []), consumedOffset: offset)
            }
            guard let newline = data.lastIndex(of: 0x0A) else {
                return Result(
                    transcript: SessionCostTranscript(
                        records: previous?.records ?? [],
                        hasUnpricedUsage: previous?.hasUnpricedUsage ?? false,
                        continuation: previous?.continuation
                    ),
                    consumedOffset: offset
                )
            }
            let complete = data[data.startIndex...newline]
            let consumed = offset + UInt64(complete.count)
            let lines = String(decoding: complete, as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: true)
            var state = ParserState(continuation: previous?.continuation)
            var records = previous?.records ?? []
            var hasUnpricedUsage = previous?.hasUnpricedUsage ?? false
            for line in lines {
                parse(
                    line: String(line),
                    provider: provider,
                    state: &state,
                    records: &records,
                    hasUnpricedUsage: &hasUnpricedUsage
                )
            }
            return Result(
                transcript: SessionCostTranscript(
                    records: records,
                    hasUnpricedUsage: hasUnpricedUsage,
                    continuation: state.continuation
                ),
                consumedOffset: consumed
            )
        } catch {
            return nil
        }
    }

    private struct ParserState {
        var modelsByTurnID: [String: String] = [:]
        var lastModelID: String?
        var seenCodexResponses: Set<String> = []
        var seenClaudeMessages: Set<String> = []
        var codexHighWater = CodexUsageTotals()
        var codexHasRecords = false
        var codexServiceTier: String?
        var cumulativeRecords: [SessionCostUsageRecord] = []

        static func codex() -> Self { Self() }
        static func claude() -> Self { Self() }

        init(continuation: SessionCostReaderContinuation? = nil) {
            guard let continuation else { return }
            modelsByTurnID = continuation.modelsByTurnID
            lastModelID = continuation.lastModelID
            seenCodexResponses = continuation.seenCodexResponses
            seenClaudeMessages = continuation.seenClaudeMessages
            codexHighWater = CodexUsageTotals(
                input: continuation.codexInput,
                cached: continuation.codexCachedInput,
                cacheWrite: continuation.codexCacheWrite,
                output: continuation.codexOutput
            )
            codexHasRecords = continuation.codexHasRecords
            codexServiceTier = continuation.codexServiceTier
            cumulativeRecords = continuation.cumulativeRecords
        }

        var continuation: SessionCostReaderContinuation {
            SessionCostReaderContinuation(
                modelsByTurnID: modelsByTurnID,
                lastModelID: lastModelID,
                seenCodexResponses: seenCodexResponses,
                seenClaudeMessages: seenClaudeMessages,
                codexInput: codexHighWater.input,
                codexCachedInput: codexHighWater.cached,
                codexCacheWrite: codexHighWater.cacheWrite,
                codexOutput: codexHighWater.output,
                codexHasRecords: codexHasRecords,
                codexServiceTier: codexServiceTier,
                cumulativeRecords: cumulativeRecords
            )
        }
    }

    private struct CodexUsageTotals: Equatable {
        var input = 0
        var cached = 0
        var cacheWrite = 0
        var output = 0

        var isEmpty: Bool {
            input == 0 && cached == 0 && cacheWrite == 0 && output == 0
        }
    }

    private static func parse(
        line: String,
        provider: SessionCostProvider,
        state: inout ParserState,
        records: inout [SessionCostUsageRecord],
        hasUnpricedUsage: inout Bool
    ) {
        guard let data = line.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        switch provider {
        case .codex:
            parseCodex(
                raw,
                state: &state,
                records: &records,
                hasUnpricedUsage: &hasUnpricedUsage
            )
        case .claude:
            parseClaude(raw, state: &state, records: &records, hasUnpricedUsage: &hasUnpricedUsage)
        }
    }

    private static func parseCodex(
        _ raw: [String: Any],
        state: inout ParserState,
        records: inout [SessionCostUsageRecord],
        hasUnpricedUsage: inout Bool
    ) {
        guard let payload = raw["payload"] as? [String: Any]
        else { return }

        let rawType = raw["type"] as? String
        let payloadType = payload["type"] as? String

        if rawType == "turn_context" {
            if let modelID = payload["model"] as? String, !modelID.isEmpty {
                state.lastModelID = modelID
                if let turnID = payload["turn_id"] as? String {
                    state.modelsByTurnID[turnID] = modelID
                }
            }
            return
        }

        if payloadType == "thread_settings_applied",
           let settings = payload["thread_settings"] as? [String: Any] {
            if let modelID = settings["model"] as? String, !modelID.isEmpty {
                state.lastModelID = modelID
            }
            if let tier = settings["service_tier"] as? String {
                state.codexServiceTier = tier
            } else if settings.keys.contains("service_tier") {
                state.codexServiceTier = ""
            }
            return
        }

        // Current Codex rollouts put the record type at the top level. Older
        // fixtures and some wrappers repeat it in the payload.
        if rawType == "token_usage_record" || payloadType == "token_usage_record",
           let usage = payload["usage"] as? [String: Any] {
            let parsedTimestamp = parseDate(raw["timestamp"]) ?? parseDate(payload["timestamp"])
            let timestamp = parsedTimestamp ?? Date()
            let modelID = codexModelID(for: payload, state: state)
            let responseID = payload["response_id"] as? String
            if let responseID, !responseID.isEmpty {
                guard state.seenCodexResponses.insert(responseID).inserted else { return }
            }
            let normalized = tokenUsage(from: usage)
            guard !normalized.isEmpty else { return }
            state.codexHasRecords = true
            // Additive per-response rows are authoritative. If an older prefix
            // only had cumulative snapshots, discard those deltas before adding
            // the first precise record; keeping both would count the same work
            // twice.
            if !state.cumulativeRecords.isEmpty {
                records.removeAll { record in
                    state.cumulativeRecords.contains(record)
                }
                state.cumulativeRecords.removeAll()
            }
            guard let modelID else {
                hasUnpricedUsage = true
                return
            }
            records.append(SessionCostUsageRecord(
                modelID: modelID,
                timestamp: timestamp,
                timestampIsKnown: parsedTimestamp != nil,
                usage: normalized.usage,
                serviceTier: state.codexServiceTier
            ))
            return
        }

        guard payloadType == "token_count",
              let info = payload["info"] as? [String: Any],
              let total = info["total_token_usage"] as? [String: Any]
        else { return }

        let current = codexTotals(from: total)
        guard !current.isEmpty else { return }
        let timestamp = parseDate(raw["timestamp"]) ?? Date()
        let modelID = codexModelID(for: payload, state: state) ?? state.lastModelID

        if state.codexHasRecords {
            return
        }

        let delta = codexDelta(current: current, previous: state.codexHighWater)
        guard !delta.isEmpty else {
            state.codexHighWater = current
            return
        }
        state.codexHighWater = current
        guard let modelID else {
            hasUnpricedUsage = true
            return
        }
        let usage = tokenUsage(from: delta)
        state.cumulativeRecords.append(SessionCostUsageRecord(
            modelID: modelID,
            timestamp: timestamp,
            timestampIsKnown: parseDate(raw["timestamp"]) != nil,
            usage: usage.usage,
            serviceTier: state.codexServiceTier
        ))
        records.removeAll()
        records.append(contentsOf: state.cumulativeRecords)
    }

    private static func codexModelID(for payload: [String: Any], state: ParserState) -> String? {
        if let turnID = payload["turn_id"] as? String,
           let modelID = state.modelsByTurnID[turnID] {
            return modelID
        }
        return state.lastModelID
    }

    private static func codexTotals(from object: [String: Any]) -> CodexUsageTotals {
        let input = integer(object["input_tokens"])
        let cached = integer(object["cached_input_tokens"])
        return CodexUsageTotals(
            input: input,
            cached: cached,
            cacheWrite: integer(object["cache_write_input_tokens"]),
            output: integer(object["output_tokens"])
        )
    }

    private static func codexDelta(current: CodexUsageTotals, previous: CodexUsageTotals) -> CodexUsageTotals {
        CodexUsageTotals(
            input: max(0, current.input - previous.input),
            cached: max(0, current.cached - previous.cached),
            cacheWrite: max(0, current.cacheWrite - previous.cacheWrite),
            output: max(0, current.output - previous.output)
        )
    }

    private static func tokenUsage(from object: [String: Any]) -> (usage: SessionTokenUsage, isEmpty: Bool) {
        let input = integer(object["input_tokens"])
        let cached = integer(object["cached_input_tokens"])
        let cacheWrite = integer(object["cache_write_input_tokens"])
        let output = integer(object["output_tokens"])
        return tokenUsage(input: input, cached: cached, cacheWrite: cacheWrite, output: output)
    }

    private static func tokenUsage(from totals: CodexUsageTotals) -> (usage: SessionTokenUsage, isEmpty: Bool) {
        tokenUsage(
            input: totals.input,
            cached: totals.cached,
            cacheWrite: totals.cacheWrite,
            output: totals.output
        )
    }

    private static func tokenUsage(
        input: Int,
        cached: Int,
        cacheWrite: Int,
        output: Int
    ) -> (usage: SessionTokenUsage, isEmpty: Bool) {
        let usage = SessionTokenUsage(
            // Codex's input_tokens includes cached and cache-write input.
            uncachedInput: max(0, input - cached - cacheWrite),
            cachedInput: cached,
            cacheWrite: cacheWrite,
            output: output
        )
        return (usage, usage.totalTokens == 0)
    }

    private static func parseClaude(
        _ raw: [String: Any],
        state: inout ParserState,
        records: inout [SessionCostUsageRecord],
        hasUnpricedUsage: inout Bool
    ) {
        guard raw["type"] as? String == "assistant",
              let message = raw["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any]
        else { return }

        let modelID = message["model"] as? String
        if modelID == "<synthetic>" { return }

        let messageID = message["id"] as? String
        if let messageID, !messageID.isEmpty {
            guard state.seenClaudeMessages.insert(messageID).inserted else { return }
        }

        let cacheCreation = usage["cache_creation"] as? [String: Any]
        let cacheWrite5m = integer(cacheCreation?["ephemeral_5m_input_tokens"])
        let cacheWrite1h = integer(cacheCreation?["ephemeral_1h_input_tokens"])
        let cacheWriteFallback = integer(usage["cache_creation_input_tokens"])
        let cacheWrite = cacheWrite5m + cacheWrite1h > 0
            ? cacheWrite5m + cacheWrite1h
            : cacheWriteFallback

        // Claude's `input_tokens` excludes both cache reads and cache writes.
        // Do not route it through Codex's normalization, which subtracts those
        // buckets from an inclusive input total.
        let normalized = SessionTokenUsage(
            uncachedInput: integer(usage["input_tokens"]),
            cachedInput: integer(usage["cache_read_input_tokens"]),
            cacheWrite: cacheWrite,
            output: integer(usage["output_tokens"])
        )
        guard normalized.totalTokens > 0 else { return }
        guard let modelID, !modelID.isEmpty else {
            hasUnpricedUsage = true
            return
        }
        let parsedTimestamp = parseDate(raw["timestamp"])
        records.append(SessionCostUsageRecord(
            modelID: modelID,
            timestamp: parsedTimestamp ?? Date(),
            timestampIsKnown: parsedTimestamp != nil,
            usage: normalized,
            serviceTier: usage["service_tier"] as? String,
            inferenceGeography: usage["inference_geo"] as? String,
            speed: usage["speed"] as? String,
            cacheWrite5m: cacheWrite5m,
            cacheWrite1h: cacheWrite1h
        ))
    }

    private static func integer(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) ?? 0 }
        return 0
    }

    private static func parseDate(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}
