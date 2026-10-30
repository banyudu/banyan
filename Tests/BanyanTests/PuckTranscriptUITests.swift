import AppKit
import BanyanCore
import PuckSwift
import SwiftUI
import Testing
import Vision
@testable import Banyan

@Suite(.serialized) @MainActor
struct PuckTranscriptUITests {
    @Test func toolStatesHaveDistinctVisibleLabels() {
        let states: [PuckToolState] = [.running, .succeeded, .failed, .truncated]
        #expect(Set(states.map(\.presentation.label)) == ["Running", "Succeeded", "Failed", "Truncated"])
        #expect(Set(states.map(\.presentation.systemImage)).count == 4)
    }

    @Test func followLogicKeepsStreamingAtTheEndButRespectsAUserScroll() {
        #expect(PuckTranscriptFollowLogic.shouldFollow(
            previousAtBottom: true,
            previousContentMaxY: 1_000,
            currentContentMaxY: 1_200,
            visibleMaxY: 850
        ))
        #expect(!PuckTranscriptFollowLogic.shouldFollow(
            previousAtBottom: false,
            previousContentMaxY: 1_000,
            currentContentMaxY: 1_200,
            visibleMaxY: 600
        ))
        #expect(PuckTranscriptFollowLogic.shouldFollow(
            previousAtBottom: false,
            previousContentMaxY: 1_000,
            currentContentMaxY: 1_000,
            visibleMaxY: 990
        ))
    }

    @Test func scrollObserverTracksTheLiveEndAndAUserScroll() async throws {
        let probe = TranscriptFollowProbe()
        let content = ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(0..<120, id: \.self) { index in
                    Text("Transcript row \(index)")
                }
            }
            .padding(12)
            .background {
                PuckTranscriptScrollObserver { probe.isFollowing = $0 }
            }
        }
        .frame(width: 360, height: 280)

        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -2_000, y: -2_000), size: NSSize(width: 360, height: 280)),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: content)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 280)
        try await Task.sleep(for: .milliseconds(200))

        let scrollView = try #require(firstScrollView(in: host))
        #expect(!probe.isFollowing)

        let bottom = max(0, (scrollView.documentView?.bounds.maxY ?? 0) - scrollView.contentView.bounds.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: bottom))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        try await Task.sleep(for: .milliseconds(100))
        #expect(probe.isFollowing)

        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!probe.isFollowing)
    }

    @Test func semanticTranscriptRendersRolesMarkdownAndCalloutsWithoutLifecycleOrCollapsedDetails() async throws {
        let timeline = PuckTimelineProjection.project(
            history: [],
            events: [
                puckTranscriptEvent(cursor: 1, kind: "user_message", text: "Inspect the parser"),
                puckTranscriptEvent(cursor: 2, kind: "assistant_message", text: """
                ## Parsed result

                - Fixed **flaky** parsing
                - [Issue details](https://example.com/parser)

                | Case | Result |
                | --- | --- |
                | Parser | Passing |

                ```swift
                let ok = true
                ```
                """, itemID: "reply"),
                puckTranscriptEvent(cursor: 3, kind: "tool_start", tool: "shell", callID: "checks",
                                    arguments: #"{"command":"swift test"}"#),
                puckTranscriptEvent(cursor: 4, kind: "tool_result", tool: "shell", callID: "checks",
                                    output: "All tests passed", success: true),
                puckTranscriptEvent(cursor: 5, kind: "turn_started"),
                puckTranscriptEvent(cursor: 6, kind: "usage", usage: PuckUsage(total: PuckTokenUsage(
                    reportedRequests: 1, inputTokens: 123, outputTokens: 45, cachedInputTokens: 0
                ))),
                puckTranscriptEvent(cursor: 7, kind: "turn_done"),
                puckTranscriptEvent(cursor: 8, kind: "hibernated", text: "Session hibernated"),
                puckTranscriptEvent(cursor: 9, kind: "turn_error", text: "Provider failed"),
                puckTranscriptEvent(cursor: 10, kind: "turn_error", text: "Turn cancelled by user"),
                puckTranscriptEvent(cursor: 11, kind: "future_event", text: "new payload",
                                    metadata: ["new_flag": "true"]),
            ]
        )

        let text = try await render(
            PuckTimelineRows(items: timeline.items)
                .padding(20)
                .frame(width: 800, height: 1_250, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor)),
            size: NSSize(width: 800, height: 1_250),
            name: "semantic-collapsed"
        )

        #expect(text.contains("You"))
        #expect(text.contains("Assistant"))
        #expect(text.contains("Parsed result"))
        #expect(text.contains("Fixed flaky parsing"))
        #expect(text.contains("Parser"))
        #expect(text.contains("Passing"))
        #expect(text.contains("let ok = true"))
        #expect(text.contains("shell"))
        #expect(text.contains("Succeeded"))
        #expect(text.contains("Error"))
        #expect(text.contains("Provider failed"))
        #expect(text.contains("Interrupted"))
        #expect(text.contains("Turn cancelled by user"))
        #expect(text.contains("Unknown event"))
        #expect(text.contains("future_event"))
        #expect(!text.contains("swift test"))
        #expect(!text.contains("All tests passed"))
        #expect(!text.contains("new payload"))
        #expect(!text.contains("turn_started"))
        #expect(!text.contains("turn_done"))
        #expect(!text.contains("hibernated"))
        #expect(!text.contains("Session hibernated"))
    }

    @Test func expandedToolAndUnknownDetailsExposeArgumentsAndOutput() async throws {
        let timeline = PuckTimelineProjection.project(
            history: [],
            events: [
                puckTranscriptEvent(cursor: 1, kind: "tool_start", tool: "shell", callID: "checks",
                                    arguments: #"{"command":"swift test"}"#),
                puckTranscriptEvent(cursor: 2, kind: "tool_result", tool: "shell", callID: "checks",
                                    output: "All tests passed", success: true),
                puckTranscriptEvent(cursor: 3, kind: "future_event", text: "new payload",
                                    metadata: ["new_flag": "true"]),
            ]
        )
        let expanded = Set(timeline.items.map(\.id))

        let text = try await render(
            PuckTimelineRows(items: timeline.items, initiallyExpandedItemIDs: expanded)
                .padding(20)
                .frame(width: 720, height: 650, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor)),
            size: NSSize(width: 720, height: 650),
            name: "semantic-expanded"
        )

        #expect(text.contains("shell"))
        #expect(text.contains("swift test"))
        #expect(text.contains("All tests passed"))
        #expect(text.contains("Unknown event"))
        #expect(text.contains("new payload"))
        #expect(text.contains("new_flag=true"))
    }

    @Test func accessibilityIdentifiersCoverTheTranscriptAndDisclosures() {
        #expect(AccessibilityID.puckTimeline == "banyan.puck.timeline")
        #expect(AccessibilityID.puckTimelineItem("call:checks") == "banyan.puck.timeline.item.call:checks")
        #expect(AccessibilityID.puckToolDisclosure("tool:checks") == "banyan.puck.timeline.tool.tool:checks")
        #expect(AccessibilityID.puckUnknownEvent("event:3") == "banyan.puck.timeline.unknown.event:3")
    }

    private func render<V: View>(_ content: V, size: NSSize, name: String) async throws -> String {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -2_000, y: -2_000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        defer { window.close() }
        let host = NSHostingView(rootView: content.preferredColorScheme(.dark))
        host.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BANYAN_PUCK_RENDER_DIR"]
            ?? NSTemporaryDirectory() + "banyan-puck-transcript-ui")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent(name + ".png"))
        return try await Task.detached {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(data: png).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        }.value
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        return view.subviews.lazy.compactMap { firstScrollView(in: $0) }.first
    }
}

@MainActor
private final class TranscriptFollowProbe: ObservableObject {
    @Published var isFollowing = true
}

private func puckTranscriptEvent(
    cursor: UInt64,
    kind: String,
    text: String? = nil,
    tool: String? = nil,
    callID: String? = nil,
    arguments: String? = nil,
    output: String? = nil,
    success: Bool? = nil,
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
        usage: usage,
        metadata: metadata
    )
}
