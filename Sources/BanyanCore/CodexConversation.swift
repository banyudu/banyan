import Foundation

/// Display cache only. Server rollout history remains authoritative. Budgets
/// cap each string tree as well as row counts, including unknown payloads.
public enum CodexConversationBudget {
    public static let turns = 40
    public static let items = 200
    public static let payloadBytes = 64 * 1024
    public static let outputBytes = 64 * 1024
    public static let diagnosticBytes = 8 * 1024
    public static let diagnostics = 200

    static func tail(_ value: String, bytes: Int) -> (text: String, omitted: Int) {
        guard value.utf8.count > bytes else { return (value, 0) }
        var result = String(decoding: value.utf8.suffix(bytes), as: UTF8.self)
        // A UTF-8 suffix may start inside a scalar. Drop that replacement.
        if result.first == "\u{fffd}" { result.removeFirst() }
        return (result, value.utf8.count - result.utf8.count)
    }

    static func payload(_ value: CodexJSONValue, bytes: Int) -> (value: CodexJSONValue, omitted: Int) {
        var remaining = bytes
        var omitted = 0
        func trim(_ value: CodexJSONValue) -> CodexJSONValue {
            switch value {
            case .string(let text):
                let clipped = tail(text, bytes: max(0, remaining))
                remaining -= clipped.text.utf8.count
                omitted += clipped.omitted
                return .string(clipped.text)
            case .array(let values):
                var result: [CodexJSONValue] = []
                for value in values {
                    guard remaining > 0 else { omitted += 1; continue }
                    remaining -= 1
                    result.append(trim(value))
                }
                return .array(result)
            case .object(let fields):
                var result: [String: CodexJSONValue] = [:]
                // Preserve discriminator/routing fields before large contents.
                let first = ["id", "type", "status", "text", "command", "path", "changes"]
                let keys = first.filter { fields[$0] != nil } + fields.keys.filter { !first.contains($0) }.sorted()
                for key in keys {
                    guard remaining >= key.utf8.count + 1 else { omitted += 1; continue }
                    remaining -= key.utf8.count + 1
                    result[key] = trim(fields[key]!)
                }
                return .object(result)
            default:
                remaining = max(0, remaining - 16)
                return value
            }
        }
        return (trim(value), omitted)
    }
}

public extension CodexJSONValue {
    var arrayValue: [CodexJSONValue] {
        if case .array(let values) = self { return values }
        return []
    }

    var inspectableText: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }
}

public struct CodexConversationItem: Identifiable, Equatable, Sendable {
    public let id: String
    public var value: CodexJSONValue
    public var output = ""
    public var isComplete = false
    public var omittedOutputBytes = 0
    public var omittedPayloadBytes = 0

    public var type: String { value.objectValue?["type"]?.stringValue ?? "unknown" }
    public var status: String? { value.objectValue?["status"]?.stringValue }
    public var text: String {
        let fields = value.objectValue ?? [:]
        switch type {
        case "agentMessage", "plan": return fields["text"]?.stringValue ?? ""
        case "userMessage":
            return (fields["content"]?.arrayValue ?? []).map {
                $0.objectValue?["text"]?.stringValue ?? $0.inspectableText
            }.joined(separator: "\n")
        case "reasoning":
            return (fields["summary"]?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: "\n")
        case "commandExecution": return fields["command"]?.stringValue ?? "Command"
        case "mcpToolCall":
            return [fields["server"]?.stringValue, fields["tool"]?.stringValue].compactMap { $0 }.joined(separator: " · ")
        case "dynamicToolCall", "collabToolCall": return fields["tool"]?.stringValue ?? type
        case "webSearch": return fields["query"]?.stringValue ?? "Web search"
        default: return type
        }
    }

    public var readableOutput: String {
        CodexConversationText.plain(output)
    }

    public var toolOutput: String {
        let fields = value.objectValue ?? [:]
        if let output = fields["output"]?.stringValue { return CodexConversationText.plain(output) }
        let result = fields["result"]?.objectValue
        let content = result?["content"]?.arrayValue ?? fields["contentItems"]?.arrayValue ?? []
        var parts = content.map { $0.objectValue?["text"]?.stringValue ?? $0.inspectableText }
        if let structured = result?["structuredContent"], structured != .null { parts.append(structured.inspectableText) }
        if let error = fields["error"], error != .null { parts.append(error.inspectableText) }
        return CodexConversationText.plain(parts.joined(separator: "\n"))
    }
}

public struct CodexConversationTurn: Identifiable, Equatable, Sendable {
    public let id: String
    public var status = "inProgress"
    public var items: [CodexConversationItem] = []
    public var diff = ""
    public var error: CodexJSONValue?
    public var omittedDiffBytes = 0
}

public struct CodexConversationDiagnostic: Identifiable, Equatable, Sendable {
    public let id: Int
    public let method: String
    public let params: CodexJSONValue
    public let omittedBytes: Int
}

/// Independent of selection and view lifetime. Item IDs are scoped to turns;
/// the owning session validates the thread ID before reducing every event.
public struct CodexConversation: Sendable {
    public private(set) var turns: [CodexConversationTurn] = []
    public private(set) var diagnostics: [CodexConversationDiagnostic] = []
    public private(set) var revision = 0
    public private(set) var omittedTurns = 0
    public private(set) var omittedItems = 0
    private var nextDiagnosticID = 0
    private var liveItems: [String: Set<String>] = [:]
    private var liveTurns: Set<String> = []

    public init() {}

    /// Resume snapshots can race notifications. Protect anything streamed
    /// during the attach RPC from being overwritten by its older snapshot.
    public mutating func beginHydration() {
        liveItems = [:]
        liveTurns = []
    }

    public mutating func releaseHistory() {
        turns = []
        diagnostics = []
        omittedTurns = 0
        omittedItems = 0
        beginHydration()
        revision += 1
    }

    public mutating func hydrate(thread: CodexJSONValue, threadID: String) {
        guard thread.objectValue?["id"]?.stringValue == threadID else { return }
        let previous = turns
        var hydrated: [CodexConversationTurn] = []
        for raw in thread.objectValue?["turns"]?.arrayValue ?? [] {
            guard let id = raw.objectValue?["id"]?.stringValue, id.utf8.count <= 1024 else {
                diagnose("history/unsupportedTurn", raw); continue
            }
            var turn = makeTurn(raw, id: id)
            if let live = previous.first(where: { $0.id == id }) {
                if liveTurns.contains(id) {
                    turn.status = live.status
                    turn.error = live.error
                    turn.diff = live.diff
                    turn.omittedDiffBytes = live.omittedDiffBytes
                }
                for item in live.items where liveItems[id]?.contains(item.id) == true {
                    if let index = turn.items.firstIndex(where: { $0.id == item.id }) { turn.items[index] = item }
                    else { turn.items.append(item) }
                }
            }
            hydrated.append(turn)
        }
        // Empty/partial resume history must not discard locally observed turns.
        hydrated.append(contentsOf: previous.filter { old in !hydrated.contains { $0.id == old.id } })
        turns = hydrated
        omittedTurns = 0
        omittedItems = 0
        trimHistory()
        revision += 1
    }

    public mutating func receive(method: String, params: CodexJSONValue, threadID: String) {
        let incomingID = params.objectValue?["threadId"]?.stringValue ?? params.objectValue?["thread"]?.objectValue?["id"]?.stringValue
        guard incomingID == nil || incomingID == threadID else { return }
        guard incomingID != nil else { diagnose(method, params); return }
        let fields = params.objectValue ?? [:]
        let rawTurn = fields["turn"]
        guard let turnID = fields["turnId"]?.stringValue ?? rawTurn?.objectValue?["id"]?.stringValue, turnID.utf8.count <= 1024 else {
            if !["thread/status/changed", "serverRequest/resolved", "thread/closed", "thread/tokenUsage/updated"].contains(method) {
                diagnose(method, params)
            }
            return
        }
        if !turns.contains(where: { $0.id == turnID }) { turns.append(.init(id: turnID)) }
        let index = turns.firstIndex { $0.id == turnID }!
        defer { trimHistory() }
        switch method {
        case "turn/started", "turn/completed":
            liveTurns.insert(turnID)
            turns[index].status = CodexConversationBudget.tail(rawTurn?.objectValue?["status"]?.stringValue ?? (method == "turn/started" ? "inProgress" : "unknown"), bytes: 256).text
            turns[index].error = rawTurn?.objectValue?["error"].map { CodexConversationBudget.payload($0, bytes: CodexConversationBudget.payloadBytes).value }
            for raw in rawTurn?.objectValue?["items"]?.arrayValue ?? [] {
                upsert(raw, turn: index, completed: method == "turn/completed")
            }
        case "item/started", "item/completed":
            guard let raw = fields["item"], raw.objectValue?["id"]?.stringValue != nil else {
                diagnose(method, params); return
            }
            upsert(raw, turn: index, completed: method == "item/completed")
        case "item/agentMessage/delta", "item/plan/delta", "item/commandExecution/outputDelta", "item/fileChange/outputDelta",
             "item/reasoning/summaryTextDelta", "item/reasoning/textDelta", "item/reasoning/summaryPartAdded":
            guard let itemID = fields["itemId"]?.stringValue, itemID.utf8.count <= 1024 else { diagnose(method, params); return }
            let type: String
            switch method {
            case "item/agentMessage/delta": type = "agentMessage"
            case "item/plan/delta": type = "plan"
            case "item/commandExecution/outputDelta": type = "commandExecution"
            case "item/fileChange/outputDelta": type = "fileChange"
            default: type = "reasoning"
            }
            if !turns[index].items.contains(where: { $0.id == itemID }) {
                upsert(.object(["id": .string(itemID), "type": .string(type)]), turn: index, completed: false)
            }
            let itemIndex = turns[index].items.firstIndex { $0.id == itemID }!
            // A late delta cannot corrupt an authoritative completed item.
            guard !turns[index].items[itemIndex].isComplete else { return }
            var item = turns[index].items[itemIndex]
            var value = item.value.objectValue ?? [:]
            let delta = fields["delta"]?.stringValue ?? ""
            if type == "agentMessage" || type == "plan" {
                value["text"] = .string((value["text"]?.stringValue ?? "") + delta)
            } else if type == "reasoning", method != "item/reasoning/textDelta" {
                let summaryIndex: Int
                if case .integer(let number)? = fields["summaryIndex"], (0..<1024).contains(number) { summaryIndex = Int(number) }
                else { summaryIndex = 0 }
                var summaries = value["summary"]?.arrayValue ?? []
                while summaries.count <= summaryIndex { summaries.append(.string("")) }
                summaries[summaryIndex] = .string((summaries[summaryIndex].stringValue ?? "") + delta)
                value["summary"] = .array(summaries)
            } else {
                let clipped = CodexConversationBudget.tail(item.output + delta, bytes: CodexConversationBudget.outputBytes)
                item.output = clipped.text
                item.omittedOutputBytes += clipped.omitted
            }
            let clipped = CodexConversationBudget.payload(.object(value), bytes: CodexConversationBudget.payloadBytes)
            item.value = clipped.value
            item.omittedPayloadBytes += clipped.omitted
            turns[index].items[itemIndex] = item
            liveItems[turnID, default: []].insert(itemID)
        case "turn/diff/updated":
            let clipped = CodexConversationBudget.tail(fields["diff"]?.stringValue ?? "", bytes: CodexConversationBudget.outputBytes)
            turns[index].diff = clipped.text
            turns[index].omittedDiffBytes = clipped.omitted
            liveTurns.insert(turnID)
        default: diagnose(method, params)
        }
        revision += 1
    }

    private func makeTurn(_ raw: CodexJSONValue, id: String) -> CodexConversationTurn {
        var turn = CodexConversationTurn(id: id)
        turn.status = CodexConversationBudget.tail(raw.objectValue?["status"]?.stringValue ?? "unknown", bytes: 256).text
        turn.error = raw.objectValue?["error"].map { CodexConversationBudget.payload($0, bytes: CodexConversationBudget.payloadBytes).value }
        turn.items = (raw.objectValue?["items"]?.arrayValue ?? []).compactMap { value in
            guard let id = value.objectValue?["id"]?.stringValue, id.utf8.count <= 1024 else { return nil }
            return makeItem(value, id: id, completed: turn.status != "inProgress")
        }
        return turn
    }

    private mutating func upsert(_ raw: CodexJSONValue, turn: Int, completed: Bool) {
        guard let id = raw.objectValue?["id"]?.stringValue, id.utf8.count <= 1024 else { return }
        var item = makeItem(raw, id: id, completed: completed)
        if let index = turns[turn].items.firstIndex(where: { $0.id == id }) {
            // Started notifications can arrive after the first delta.
            let old = turns[turn].items[index]
            if !completed {
                if old.isComplete { return }
                var fields = raw.objectValue ?? [:]
                for key in ["text", "summary"] where old.value.objectValue?[key] != nil { fields[key] = old.value.objectValue?[key] }
                let clipped = CodexConversationBudget.payload(.object(fields), bytes: CodexConversationBudget.payloadBytes)
                item.value = clipped.value
                item.omittedPayloadBytes += old.omittedPayloadBytes + clipped.omitted
            }
            if raw.objectValue?["aggregatedOutput"]?.stringValue == nil {
                item.output = old.output
                item.omittedOutputBytes = old.omittedOutputBytes
            }
            turns[turn].items[index] = item
        } else { turns[turn].items.append(item) }
        liveItems[turns[turn].id, default: []].insert(id)
    }

    private mutating func diagnose(_ method: String, _ params: CodexJSONValue) {
        let clipped = CodexConversationBudget.payload(params, bytes: CodexConversationBudget.diagnosticBytes)
        diagnostics.append(.init(id: nextDiagnosticID, method: CodexConversationBudget.tail(method, bytes: 1024).text, params: clipped.value, omittedBytes: clipped.omitted))
        nextDiagnosticID += 1
        if diagnostics.count > CodexConversationBudget.diagnostics { diagnostics.removeFirst(diagnostics.count - CodexConversationBudget.diagnostics) }
        revision += 1
    }

    private func makeItem(_ raw: CodexJSONValue, id: String, completed: Bool) -> CodexConversationItem {
        var fields = raw.objectValue ?? [:]
        let output = CodexConversationBudget.tail(fields["aggregatedOutput"]?.stringValue ?? "", bytes: CodexConversationBudget.outputBytes)
        // Store output once, separate from the bounded metadata tree.
        if fields["aggregatedOutput"] != nil { fields["aggregatedOutput"] = .string("[Output shown separately]") }
        let clipped = CodexConversationBudget.payload(.object(fields), bytes: CodexConversationBudget.payloadBytes)
        return .init(id: id, value: clipped.value, output: output.text, isComplete: completed,
            omittedOutputBytes: output.omitted, omittedPayloadBytes: clipped.omitted)
    }

    private mutating func trimHistory() {
        if turns.count > CodexConversationBudget.turns {
            let count = turns.count - CodexConversationBudget.turns
            omittedTurns += count
            omittedItems += turns.prefix(count).reduce(0) { $0 + $1.items.count }
            turns.removeFirst(count)
        }
        var excess = turns.reduce(0) { $0 + $1.items.count } - CodexConversationBudget.items
        for index in turns.indices where excess > 0 {
            let count = min(excess, turns[index].items.count)
            turns[index].items.removeFirst(count)
            excess -= count
            omittedItems += count
        }
        liveTurns.formIntersection(turns.map(\.id))
        liveItems = liveItems.filter { id, _ in turns.contains { $0.id == id } }
        for turn in turns { liveItems[turn.id]?.formIntersection(turn.items.map(\.id)) }
    }
}

/// Render structured output as text, never as a terminal or escape interpreter.
public enum CodexConversationText {
    private static let terminalEscapes = try! NSRegularExpression(
        pattern: "\u{001B}\\][^\u{0007}\u{001B}]*(?:\u{0007}|\u{001B}\\\\)|\u{001B}\\[[0-?]*[ -/]*[@-~]"
    )
    public static func plain(_ text: String) -> String {
        let clean = terminalEscapes.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        return String(clean.unicodeScalars.filter { $0.value >= 32 || $0 == "\n" || $0 == "\t" })
    }
}
