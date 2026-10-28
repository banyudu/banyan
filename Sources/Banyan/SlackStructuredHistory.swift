import BanyanCore
import Foundation

/// Short-lived presentation snapshots. Provider thread identity and item IDs
/// are part of the cursor fence; app restart simply invalidates old cursors.
@MainActor
final class SlackStructuredHistory {
    struct Entry: Equatable {
        let id: String
        let role: String
        let text: String
        let truncated: Bool
    }
    struct Page {
        let entries: [Entry]
        let earlier: String?
        let truncated: Bool
    }
    private struct Snapshot {
        let sessionID: String
        let threadID: String
        let entries: [Entry]
        let truncated: Bool
    }
    private var snapshots: [UUID: Snapshot] = [:]
    private var order: [UUID] = []

    func page(sessionID: String, threadID: String, entries: [Entry], truncated: Bool,
              cursor: String?, limit: Int) throws -> Page {
        let id: UUID
        let snapshot: Snapshot
        let end: Int
        if let cursor {
            let fields = cursor.split(separator: ":", omittingEmptySubsequences: false)
            guard fields.count == 2, let parsed = UUID(uuidString: String(fields[0])),
                  let index = Int(fields[1]), let stored = snapshots[parsed],
                  stored.sessionID == sessionID, stored.threadID == threadID,
                  stored.truncated == truncated, entries.starts(with: stored.entries),
                  (0...stored.entries.count).contains(index) else {
                throw CodexRemoteError.invalid("Conversation changed; open latest history")
            }
            id = parsed; snapshot = stored; end = index
        } else {
            id = UUID(); snapshot = Snapshot(sessionID: sessionID, threadID: threadID, entries: entries, truncated: truncated)
            snapshots[id] = snapshot; order.append(id)
            while order.count > 8 { snapshots.removeValue(forKey: order.removeFirst()) }
            end = entries.count
        }
        let start = max(0, end - min(max(limit, 1), 100))
        return Page(entries: Array(snapshot.entries[start..<end]),
                    earlier: start > 0 ? "\(id.uuidString):\(start)" : nil,
                    truncated: snapshot.truncated || snapshot.entries[start..<end].contains(where: \.truncated))
    }

    static func entries(_ history: PuckRecentHistory) -> [Entry] {
        PuckTranscript.render(history.events).compactMap { event in
            let role: String
            switch event.kind {
            case "text_delta", "turn_done": role = "assistant"
            case "tool_result", "hosted_call": role = "tool"
            case "turn_error", "persistence_error", "audit_error": role = "status"
            default: return nil
            }
            guard !event.text.isEmpty else { return nil }
            return Entry(id: String(event.id), role: role, text: String(event.text.prefix(8_000)), truncated: event.text.count > 8_000)
        }
    }

    static func entries(_ conversation: CodexConversation) -> [Entry] {
        conversation.turns.flatMap { turn in
            turn.items.compactMap { item -> Entry? in
                let role: String
                switch item.type {
                case "userMessage": role = "user"
                case "agentMessage", "plan": role = "assistant"
                case "commandExecution", "mcpToolCall", "dynamicToolCall", "collabToolCall", "webSearch": role = "tool"
                default: return nil
                }
                let output = item.readableOutput.isEmpty ? item.toolOutput : item.readableOutput
                let body = ([item.text] + (role == "tool" && !output.isEmpty ? [output] : []))
                    .filter { !$0.isEmpty }.joined(separator: "\n")
                guard !body.isEmpty else { return nil }
                return Entry(id: "\(turn.id.utf8.count):\(turn.id)\(item.id)", role: role,
                             text: String(body.prefix(8_000)),
                             truncated: body.count > 8_000 || item.omittedOutputBytes > 0 || item.omittedPayloadBytes > 0)
            }
        }
    }
}
