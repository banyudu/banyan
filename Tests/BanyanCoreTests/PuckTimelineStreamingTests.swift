import BanyanCore
import Foundation
import PuckSwift
import Testing

/// Live reasoning, streamed command output and image attachments.
struct PuckTimelineStreamingTests {
    @Test func reasoningStreamsIntoOneRowAndSettlesWhenItsItemFinishes() {
        let streaming = [
            PuckSessionEvent(cursor: 1, kind: "turn_started"),
            PuckSessionEvent(cursor: 1, kind: "reasoning_delta", text: "**Inspecting", transient: true, itemID: "r1"),
            PuckSessionEvent(cursor: 1, kind: "reasoning_delta", text: " files**\n\nReading Package.swift.",
                             transient: true, itemID: "r1"),
        ]
        let live = PuckTimelineProjection.project(history: [], events: streaming)
        #expect(live.items.map(\.role) == [.reasoning])
        #expect(live.items.first?.isStreaming == true)
        #expect(live.items.first?.text == "**Inspecting files**\n\nReading Package.swift.")
        #expect(live.activity == "Inspecting files")

        let finished = PuckTimelineProjection.project(history: [], events: streaming + [
            PuckSessionEvent(cursor: 2, kind: "reasoning", text: "**Inspecting files**\n\nReading Package.swift.",
                             itemID: "r1"),
        ])
        #expect(finished.items.count == 1)
        #expect(finished.items.first?.isStreaming == false)
        #expect(finished.items.first?.id == live.items.first?.id)

        let done = PuckTimelineProjection.project(history: [], events: streaming + [
            PuckSessionEvent(cursor: 3, kind: "turn_done"),
        ])
        #expect(done.activity == nil)
        #expect(done.items.first?.isStreaming == false)
    }

    @Test func historyReasoningMatchesItsLiveEventWithoutDuplicating() {
        let history = [PuckHistoryItem(id: "r1", turnID: "t1", kind: "reasoning", text: "**Plan**\n\nStep one")]
        let timeline = PuckTimelineProjection.project(history: history, events: [
            PuckSessionEvent(cursor: 4, kind: "reasoning", text: "**Plan**\n\nStep one", itemID: "r1"),
        ])
        #expect(timeline.items.map(\.role) == [.reasoning])
        #expect(PuckTimelineContent.reasoningHeading(timeline.items[0].text) == "Plan")
    }

    @Test func commandOutputStreamsUntilTheResultReplacesIt() {
        let start = PuckSessionEvent(cursor: 1, kind: "tool_start", tool: "exec_command", callID: "c1",
                                     arguments: #"{"cmd":"make test"}"#)
        let deltas = [
            PuckSessionEvent(cursor: 1, kind: "tool_output_delta", callID: "c1", output: "compiling\n", transient: true),
            PuckSessionEvent(cursor: 1, kind: "tool_output_delta", callID: "c1", output: "testing\n", transient: true),
        ]
        let live = PuckTimelineProjection.project(history: [], events: [start] + deltas)
        guard case .tool(let running) = live.items.first?.content else {
            Issue.record("expected a tool row"); return
        }
        #expect(running.state == .running)
        #expect(running.output == "compiling\ntesting\n")
        #expect(live.items.first?.isStreaming == true)

        let finished = PuckTimelineProjection.project(history: [], events: [start] + deltas + [
            PuckSessionEvent(cursor: 2, kind: "tool_result", tool: "exec_command", callID: "c1",
                             output: "compiling\ntesting\nok", success: true),
        ])
        guard case .tool(let done) = finished.items.first?.content else {
            Issue.record("expected a tool row"); return
        }
        #expect(done.state == .succeeded)
        #expect(done.output == "compiling\ntesting\nok")
        #expect(finished.items.first?.isStreaming == false)
    }

    @Test func chattyCommandOutputKeepsOnlyItsNewestText() {
        let line = String(repeating: "x", count: 99) + "\n"
        let events = [PuckSessionEvent(cursor: 1, kind: "tool_start", tool: "exec_command", callID: "c1")]
            + (0..<1_000).map { _ in
                PuckSessionEvent(cursor: 1, kind: "tool_output_delta", callID: "c1", output: line, transient: true)
            }
            + [PuckSessionEvent(cursor: 1, kind: "tool_output_delta", callID: "c1", output: "last line\n", transient: true)]
        let timeline = PuckTimelineProjection.project(history: [], events: events)
        guard case .tool(let tool) = timeline.items.first?.content else {
            Issue.record("expected a tool row"); return
        }
        #expect(tool.output.utf8.count <= 64 * 1024)
        #expect(tool.output.hasSuffix("last line\n"))
        #expect(tool.output.hasPrefix("x"))
    }

    @Test func userImagesComeFromLiveEventsAndHistory() {
        let live = PuckTimelineProjection.project(history: [], events: [
            PuckSessionEvent(cursor: 1, kind: "user_message", text: "What is this?", images: ["/tmp/a.png"]),
        ])
        #expect(live.items.first?.images == ["/tmp/a.png"])

        let history = PuckTimelineProjection.project(history: [
            PuckHistoryItem(id: "u1", kind: "user", text: "", images: ["/tmp/b.png"]),
            PuckHistoryItem(id: "a1", kind: "assistant", text: "A chart.", images: ["/tmp/ignored.png"]),
        ], events: [])
        #expect(history.items.map(\.images) == [["/tmp/b.png"], []])
    }

    @Test func engineReconnectsShowAsActivityNotAsUnknownRows() {
        let timeline = PuckTimelineProjection.project(history: [], events: [
            PuckSessionEvent(cursor: 1, kind: "turn_started"),
            PuckSessionEvent(cursor: 2, kind: "model_retry", message: "stream disconnected"),
        ])
        #expect(timeline.items.isEmpty)
        #expect(timeline.activity == "Reconnecting: stream disconnected")
    }
}
