import BanyanCore
import Foundation
import PuckSwift
import Testing

@Suite("Puck timeline projection")
struct PuckTimelineTests {
    @Test func historyOnlyNormalizesTypedRolesAndTurnIdentity() {
        let history = [
            PuckHistoryItem(id: "user-1", turnID: "turn-1", kind: "user", text: "Inspect"),
            PuckHistoryItem(id: "assistant-1", turnID: "turn-1", kind: "assistant", text: "Done"),
            PuckHistoryItem(id: "call-1", turnID: "turn-1", kind: "tool", text: "canonical output"),
            PuckHistoryItem(id: "future-1", kind: "future_history", text: "new data"),
        ]

        let timeline = PuckTimelineProjection.project(history: history, events: [])

        #expect(timeline.items.map(\.role) == [.user, .assistant, .tool, .unknown])
        #expect(timeline.items[0].text == "Inspect")
        #expect(timeline.items[1].turnID == "turn-1")
        guard case .tool(let tool) = timeline.items[2].content else {
            Issue.record("History tool item was not normalized as tool activity")
            return
        }
        #expect(tool.callID == "call-1")
        #expect(tool.output == "canonical output")
        #expect(tool.state == .succeeded)
        guard case .unknown(let kind, let detail) = timeline.items[3].content else {
            Issue.record("Unknown history kind was dropped")
            return
        }
        #expect(kind == "future_history")
        #expect(detail == "new data")
    }

    @Test func liveOnlyMergesStreamingTextAndKeepsLifecycleOut() {
        let events = [
            puckEvent(cursor: 1, kind: "turn_started"),
            puckEvent(cursor: 2, kind: "user_message", text: "Hello"),
            puckEvent(cursor: 3, kind: "text_delta", text: "Hel", transient: true),
            puckEvent(cursor: 3, kind: "text_delta", text: "lo", transient: true),
            puckEvent(cursor: 4, kind: "assistant_message", text: "Hello", itemID: "assistant-1",
                      historyRef: "assistant-1"),
            puckEvent(cursor: 5, kind: "usage", usage: PuckUsage(total: PuckTokenUsage(
                reportedRequests: 2, inputTokens: 120, outputTokens: 30, cachedInputTokens: 80
            ))),
            puckEvent(cursor: 6, kind: "turn_done", text: "Finished"),
            puckEvent(cursor: 7, kind: "approval_pending", tool: "shell"),
            puckEvent(cursor: 8, kind: "presence_changed"),
        ]

        let timeline = PuckTimelineProjection.project(history: [], events: events)

        #expect(timeline.items.map(\.role) == [.user, .assistant])
        #expect(timeline.items.map(\.text) == ["Hello", "Hello"])
        #expect(timeline.items[1].id == "item:assistant-1")
        #expect(timeline.usage?.total.inputTokens == 120)
        #expect(timeline.usage?.total.outputTokens == 30)
    }

    @Test func historyAndLiveOverlapUseStableIdentityWithoutDuplicates() {
        let history = [
            PuckHistoryItem(id: "user-1", turnID: "turn-1", kind: "user", text: "Inspect"),
            PuckHistoryItem(id: "assistant-1", turnID: "turn-1", kind: "assistant", text: "Canonical answer"),
            PuckHistoryItem(id: "call-1", turnID: "turn-1", kind: "tool", text: "canonical output"),
        ]
        let events = [
            puckEvent(cursor: 10, kind: "user_message", text: "Inspect", historyRef: "user-1"),
            puckEvent(cursor: 11, kind: "assistant_message", text: "Canonical answer", itemID: "assistant-1",
                      historyRef: "assistant-1"),
            puckEvent(cursor: 12, kind: "assistant_message", text: "Canonical answer", itemID: "assistant-1",
                      historyRef: "assistant-1"),
            puckEvent(cursor: 13, kind: "tool_start", tool: "shell", callID: "call-1",
                      arguments: #"{"command":"ls"}"#),
            puckEvent(cursor: 14, kind: "tool_result", tool: "shell", callID: "call-1",
                      output: "live output", success: true),
        ]

        let timeline = PuckTimelineProjection.project(history: history, events: events)

        #expect(timeline.items.count == 3)
        #expect(timeline.items.map(\.text) == ["Inspect", "Canonical answer", "canonical output"])
        guard case .tool(let tool) = timeline.items[2].content else {
            Issue.record("Tool history and live result were not paired")
            return
        }
        #expect(tool.name == "shell")
        #expect(tool.arguments == #"{"command":"ls"}"#)
        #expect(tool.output == "canonical output")
        #expect(tool.state == .succeeded)
    }

    @Test func toolCallsAppearOnceAndReachFailedRunningAndTruncatedStates() {
        let events = [
            puckEvent(cursor: 20, kind: "tool_start", tool: "shell", callID: "failed-call", arguments: "false"),
            puckEvent(cursor: 21, kind: "tool_result", tool: "shell", callID: "failed-call",
                      output: "denied", success: false),
            puckEvent(cursor: 22, kind: "tool_start", tool: "search", callID: "running-call", arguments: "query"),
            puckEvent(cursor: 23, kind: "tool_start", tool: "read", callID: "truncated-call", arguments: "file"),
            puckEvent(cursor: 24, kind: "tool_result", tool: "read", callID: "truncated-call",
                      output: "partial", success: true, truncated: true),
        ]

        let timeline = PuckTimelineProjection.project(history: [], events: events)

        #expect(timeline.items.count == 3)
        #expect(timeline.items.compactMap { item -> String? in
            guard case .tool(let tool) = item.content else { return nil }
            return "\(tool.callID):\(tool.state.rawValue)"
        } == ["failed-call:failed", "running-call:running", "truncated-call:truncated"])
        #expect(timeline.items.compactMap { item -> String? in
            guard case .tool(let tool) = item.content else { return nil }
            return tool.arguments
        } == ["false", "query", "file"])
    }

    @Test func unknownEventKindsRemainInspectable() {
        let event = puckEvent(
            cursor: 31,
            kind: "future_event",
            text: "new payload",
            metadata: ["new_flag": "true", "count": "3"]
        )

        let timeline = PuckTimelineProjection.project(history: [], events: [event])

        #expect(timeline.items.count == 1)
        #expect(timeline.items[0].role == .unknown)
        guard case .unknown(let kind, let detail) = timeline.items[0].content else {
            Issue.record("Unknown event kind was dropped")
            return
        }
        #expect(kind == "future_event")
        #expect(detail.contains("new payload"))
        #expect(detail.contains("new_flag=true"))
        #expect(detail.contains("count=3"))
    }

    @Test func errorsAndInterruptionsAreConversationItemsButLifecycleIsNot() {
        let events = [
            puckEvent(cursor: 41, kind: "turn_error", text: "provider failed"),
            puckEvent(cursor: 42, kind: "turn_error", text: "turn cancelled by user"),
            puckEvent(cursor: 43, kind: "hibernated", text: "Session hibernated"),
        ]

        let timeline = PuckTimelineProjection.project(history: [], events: events)

        #expect(timeline.items.map(\.role) == [.error, .interruption])
        #expect(timeline.items.map(\.text) == ["provider failed", "turn cancelled by user"])
    }

    @Test func projectionEvictsOldestItemsWithinItemAndByteLimits() {
        let events = (0..<20).map { index in
            puckEvent(cursor: UInt64(index + 1), kind: "user_message",
                      text: String(repeating: "x", count: 120), itemID: "message-\(index)")
        }

        let timeline = PuckTimelineProjection.project(
            history: [],
            events: events,
            limits: PuckTimelineLimits(maxItems: 4, maxBytes: 1_000)
        )

        #expect(!timeline.items.isEmpty)
        #expect(timeline.items.count <= 4)
        #expect(timeline.items.reduce(0, { $0 + $1.retainedByteCount }) <= 1_000)
        #expect(timeline.items.last?.id == "item:message-19")
        #expect(!timeline.items.contains { $0.id == "item:message-0" })
    }
}

private func puckEvent(
    cursor: UInt64,
    kind: String,
    text: String? = nil,
    tool: String? = nil,
    callID: String? = nil,
    arguments: String? = nil,
    output: String? = nil,
    success: Bool? = nil,
    truncated: Bool = false,
    transient: Bool = false,
    itemID: String? = nil,
    historyRef: String? = nil,
    turnID: String? = nil,
    usage: PuckUsage? = nil,
    metadata: [String: String] = [:]
) -> PuckSessionEvent {
    PuckSessionEvent(
        cursor: cursor,
        kind: kind,
        text: text,
        tool: tool,
        callID: callID,
        arguments: arguments,
        output: output,
        transient: transient,
        itemID: itemID,
        historyRef: historyRef,
        turnID: turnID,
        success: success,
        truncated: truncated,
        usage: usage,
        metadata: metadata
    )
}
