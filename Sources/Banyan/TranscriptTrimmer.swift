import BanyanCore
import Foundation

/// Mechanically trims stale tool-call output from a coding-agent transcript so a
/// resumed session replays far fewer input tokens per turn, without an LLM in the
/// loop. This is the client-side analog of the Messages API's context-editing
/// pass (`clear_tool_uses`): it *clears* old tool results, it does not summarize.
///
/// Only oversized tool-result payloads that are not among the most recent
/// `keepRecentResults` are replaced with a short placeholder. Every transcript
/// line is preserved verbatim except the ones actually trimmed, so the
/// `uuid`/`parentUuid` chain and each `tool_use`↔`tool_result` pairing stay
/// intact. Returns nil whenever nothing was trimmed (or the transcript looks
/// unexpected), so callers can fall back to an untouched full resume.
enum TranscriptTrimmer {
    struct Config: Equatable {
        /// Only tool results whose serialized payload exceeds this are eligible.
        var minResultBytes: Int
        /// Never trim the most recent N tool results — they are the most likely
        /// to still be load-bearing for the next turn.
        var keepRecentResults: Int

        static let `default` = Config(minResultBytes: 2048, keepRecentResults: 8)
    }

    struct Outcome: Equatable {
        var content: String
        var trimmedCount: Int
        var bytesSaved: Int
    }

    /// One trimmable tool-result payload located within the transcript.
    private struct Unit {
        let lineIndex: Int
        /// Index into `message.content` (claude); always 0 for codex (one output
        /// per line).
        let blockIndex: Int
        let size: Int
    }

    static func placeholder(originalBytes: Int) -> String {
        "[Banyan trimmed \(originalBytes) bytes of tool output to save context]"
    }

    static func trim(
        contents: String,
        provider: CodingAgentProvider,
        oldSessionID: String,
        newSessionID: String,
        config: Config = .default
    ) -> Outcome? {
        guard [.codex, .claude].contains(provider) else { return nil }
        guard oldSessionID != newSessionID, !newSessionID.isEmpty else { return nil }

        // components(separatedBy:) keeps empty trailing element, so joining with
        // "\n" reproduces the original line/newline structure exactly.
        var lines = contents.components(separatedBy: "\n")

        // Pass 1: locate every trimmable unit in file order, caching the parsed
        // object only for lines that carry one (so pass 2 can reuse it).
        var units: [Unit] = []
        var parsedByLine: [Int: [String: Any]] = [:]
        for (index, line) in lines.enumerated() {
            guard !line.isEmpty, let object = jsonObject(from: line) else { continue }
            let lineUnits: [Unit]
            switch provider {
            case .claude:
                lineUnits = claudeUnits(in: object, lineIndex: index)
            case .codex:
                lineUnits = codexUnits(in: object, lineIndex: index)
            default:
                lineUnits = []
            }
            if !lineUnits.isEmpty {
                parsedByLine[index] = object
                units.append(contentsOf: lineUnits)
            }
        }

        guard units.count > config.keepRecentResults else { return nil }

        // Protect the most recent `keepRecentResults`; among the rest, trim only
        // the ones that actually exceed the size threshold.
        let trimmable = units
            .prefix(units.count - config.keepRecentResults)
            .filter { $0.size > config.minResultBytes }
        guard !trimmable.isEmpty else { return nil }

        // Group the surviving trims by line so each line is rewritten once.
        var blocksByLine: [Int: Set<Int>] = [:]
        var bytesSaved = 0
        for unit in trimmable {
            blocksByLine[unit.lineIndex, default: []].insert(unit.blockIndex)
            bytesSaved += unit.size
        }

        var trimmedCount = 0
        for (lineIndex, blocks) in blocksByLine {
            guard var object = parsedByLine[lineIndex] else { continue }
            let rewritten: Bool
            switch provider {
            case .claude:
                rewritten = rewriteClaudeLine(&object, blocks: blocks)
            case .codex:
                rewritten = rewriteCodexLine(&object)
            default:
                rewritten = false
            }
            guard rewritten, let serialized = jsonLine(from: object) else { continue }
            lines[lineIndex] = serialized
            trimmedCount += blocks.count
        }

        guard trimmedCount > 0 else { return nil }

        // Re-key the transcript to the new session id. The session UUID is unique
        // and distinct from message uuids, so a global replacement is safe and
        // leaves every non-trimmed line byte-identical.
        let content = lines
            .joined(separator: "\n")
            .replacingOccurrences(of: oldSessionID, with: newSessionID)
        return Outcome(content: content, trimmedCount: trimmedCount, bytesSaved: bytesSaved)
    }

    // MARK: - Claude

    private static func claudeUnits(in object: [String: Any], lineIndex: Int) -> [Unit] {
        guard object["type"] as? String == "user",
              let message = object["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else {
            return []
        }
        return content.enumerated().compactMap { blockIndex, block in
            guard block["type"] as? String == "tool_result",
                  let payload = block["content"] else {
                return nil
            }
            return Unit(lineIndex: lineIndex, blockIndex: blockIndex, size: payloadSize(payload))
        }
    }

    private static func rewriteClaudeLine(_ object: inout [String: Any], blocks: Set<Int>) -> Bool {
        guard var message = object["message"] as? [String: Any],
              var content = message["content"] as? [[String: Any]] else {
            return false
        }
        var changed = false
        for blockIndex in blocks where content.indices.contains(blockIndex) {
            guard content[blockIndex]["type"] as? String == "tool_result",
                  let payload = content[blockIndex]["content"] else {
                continue
            }
            content[blockIndex]["content"] = placeholder(originalBytes: payloadSize(payload))
            changed = true
        }
        guard changed else { return false }
        message["content"] = content
        object["message"] = message
        return true
    }

    // MARK: - Codex

    private static func codexUnits(in object: [String: Any], lineIndex: Int) -> [Unit] {
        guard object["type"] as? String == "response_item",
              let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "function_call_output",
              let output = payload["output"] else {
            return []
        }
        return [Unit(lineIndex: lineIndex, blockIndex: 0, size: codexOutputSize(output))]
    }

    private static func rewriteCodexLine(_ object: inout [String: Any]) -> Bool {
        guard var payload = object["payload"] as? [String: Any],
              let output = payload["output"] else {
            return false
        }
        let size = codexOutputSize(output)
        if var outputObject = output as? [String: Any], outputObject["content"] is String {
            outputObject["content"] = placeholder(originalBytes: size)
            payload["output"] = outputObject
        } else {
            payload["output"] = placeholder(originalBytes: size)
        }
        object["payload"] = payload
        return true
    }

    /// Codex `function_call_output.output` is usually a bare string, but some
    /// versions wrap it as `{content, metadata}`.
    private static func codexOutputSize(_ output: Any) -> Int {
        if let outputObject = output as? [String: Any], let content = outputObject["content"] as? String {
            return content.utf8.count
        }
        return payloadSize(output)
    }

    // MARK: - Helpers

    private static func payloadSize(_ payload: Any) -> Int {
        if let text = payload as? String {
            return text.utf8.count
        }
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            return data.count
        }
        return 0
    }

    private static func jsonObject(from line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private static func jsonLine(from object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]),
              let line = String(data: data, encoding: .utf8) else {
            return nil
        }
        return line
    }
}
