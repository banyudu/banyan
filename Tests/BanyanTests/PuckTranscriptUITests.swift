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

    @Test func transcriptTypographyMirrorsTheConfiguredTerminalFont() {
        let typography = PuckTranscriptTypography(fontFamily: "Menlo", fontSize: 18)

        #expect(typography.markdownStyle == .transcript(fontFamily: "Menlo", fontSize: 18))
        #expect(typography.markdownStyle.lineSpacing > 2)
        #expect(typography.detailFontSize == 17)
        #expect(typography.captionFontSize == 16)
        #expect(typography.rowSpacing > 18)

        let unavailable = PuckTranscriptTypography(fontFamily: "Missing Font", fontSize: 18)
        #expect(unavailable.markdownStyle == .transcript(fontFamily: nil, fontSize: 18))
    }

    @Test func adjacentToolCallsShareOneTranscriptRow() {
        let tool = { (index: Int) in
            PuckTimelineItem(
                id: "tool-\(index)",
                role: .tool,
                content: .tool(PuckToolActivity(
                    callID: "call-\(index)",
                    name: "exec_command",
                    output: "result \(index)",
                    state: .succeeded
                )),
                turnID: "turn-1"
            )
        }
        let items = [
            PuckTimelineItem(id: "user-1", role: .user, content: .user("Inspect"), turnID: "turn-1"),
            tool(1),
            tool(2),
            tool(3),
            PuckTimelineItem(id: "assistant-1", role: .assistant, content: .assistant("Done"), turnID: "turn-1"),
        ]

        let entries = PuckTranscriptLayout.entries(for: items)

        #expect(entries.count == 3)
        guard case .toolGroup(let grouped) = entries[1] else {
            Issue.record("Adjacent tool calls were not grouped")
            return
        }
        #expect(grouped.map(\.id) == ["tool-1", "tool-2", "tool-3"])
        let summary = PuckToolGroupSummary(items: grouped)
        #expect(summary.title == "Ran 3 commands")
        #expect(summary.detail == nil)
    }

    @Test func collapsedToolHistoryShowsOnlyTheGroupSummary() async throws {
        let timeline = PuckTimelineProjection.project(
            history: [],
            events: [
                puckTranscriptEvent(cursor: 1, kind: "user_message", text: "Inspect the parser"),
                puckTranscriptEvent(cursor: 2, kind: "tool_start", tool: "exec_command", callID: "first",
                                    arguments: #"{"cmd":"swift test"}"#),
                puckTranscriptEvent(cursor: 3, kind: "tool_result", tool: "exec_command", callID: "first",
                                    output: "exit code: 0\n--- stdout ---\nfirst result", success: true),
                puckTranscriptEvent(cursor: 4, kind: "tool_start", tool: "exec_command", callID: "second",
                                    arguments: #"{"cmd":"swift build"}"#),
                puckTranscriptEvent(cursor: 5, kind: "tool_result", tool: "exec_command", callID: "second",
                                    output: "exit code: 0\n--- stdout ---\nsecond result", success: true),
                puckTranscriptEvent(cursor: 6, kind: "tool_start", tool: "exec_command", callID: "third",
                                    arguments: #"{"cmd":"git status"}"#),
                puckTranscriptEvent(cursor: 7, kind: "tool_result", tool: "exec_command", callID: "third",
                                    output: "exit code: 0\n--- stdout ---\nthird result", success: true),
            ]
        )

        let collapsed = try await render(
            PuckTimelineRows(items: timeline.items)
                .padding(20)
                .frame(width: 800, height: 500, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor)),
            size: NSSize(width: 800, height: 500),
            name: "tool-history-collapsed"
        )

        #expect(collapsed.contains("Ran 3 commands"))
        #expect(!collapsed.contains("swift test"))
        #expect(!collapsed.contains("first result"))
        #expect(!collapsed.contains("stdout"))

        let expanded = try await render(
            PuckTimelineRows(
                items: timeline.items,
                initiallyExpandedItemIDs: Set(timeline.items.map(\.id))
            )
                .padding(20)
                .frame(width: 800, height: 1_200, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor)),
            size: NSSize(width: 800, height: 1_200),
            name: "tool-history-expanded"
        )

        #expect(expanded.contains("swift test"))
        #expect(expanded.contains("first result"))
        #expect(!expanded.contains("exit code"))
        #expect(!expanded.contains("--- stdout ---"))
    }

    @Test func historyToolCallWrapperIsNotRenderedAsOutput() async throws {
        let timeline = PuckTimelineProjection.project(
            history: [
                PuckHistoryItem(id: "native-1", turnID: "turn-1", kind: "tool", text: "exec_command"),
                PuckHistoryItem(
                    id: "native-2",
                    turnID: "turn-1",
                    kind: "tool",
                    text: "exit code: 0\n--- stdout ---\nAll tests passed"
                ),
            ],
            events: []
        )

        let text = try await render(
            PuckTimelineRows(
                items: timeline.items,
                initiallyExpandedItemIDs: Set(timeline.items.map(\.id))
            )
                .padding(20)
                .frame(width: 720, height: 420, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor)),
            size: NSSize(width: 720, height: 420),
            name: "history-tool-call-wrapper"
        )

        #expect(text.contains("Ran Command"))
        #expect(text.contains("All tests passed"))
        #expect(!text.contains("exec_command"))
        #expect(!text.contains("exit code"))
    }

    @Test func protocol22HistoryShowsTheCommandBehindTheToolCall() async throws {
        let timeline = PuckTimelineProjection.project(
            history: [
                PuckHistoryItem(
                    id: "call-1",
                    turnID: "turn-1",
                    kind: "tool_call",
                    text: "exec_command",
                    toolName: "exec_command",
                    callID: "call-abc",
                    arguments: #"{"cmd":"cat src/app/sitemap.ts"}"#
                ),
                PuckHistoryItem(
                    id: "result-1",
                    turnID: "turn-1",
                    kind: "tool_result",
                    text: "exit code: 0\n--- stdout ---\nimport type { MetadataRoute } from \"next\";",
                    callID: "call-abc"
                ),
            ],
            events: []
        )

        let text = try await render(
            PuckTimelineRows(
                items: timeline.items,
                initiallyExpandedItemIDs: Set(timeline.items.map(\.id))
            )
                .padding(20)
                .frame(width: 760, height: 460, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor)),
            size: NSSize(width: 760, height: 460),
            name: "protocol22-history-tool-call"
        )

        #expect(text.contains("cat src/app/sitemap.ts")
            || compactOCR(text).contains(compactOCR("cat src/app/sitemap.ts")))
        #expect(text.contains("MetadataRoute"))
        #expect(!text.contains("exec_command"))
        #expect(!text.contains("exit code"))
    }

    @Test func toolResultJSONIsPrettyPrintedAndLabeled() async throws {
        let timeline = PuckTimelineProjection.project(
            history: [],
            events: [
                puckTranscriptEvent(cursor: 1, kind: "tool_start", tool: "tool", callID: "workers",
                                    arguments: #"{"query":"workers"}"#),
                puckTranscriptEvent(
                    cursor: 2,
                    kind: "tool_result",
                    tool: "tool",
                    callID: "workers",
                    output: #"[{"class":"worker","engine":"native","id":"worker-1","ready":true}]"#,
                    success: true
                ),
            ]
        )

        let text = try await render(
            PuckTimelineRows(
                items: timeline.items,
                initiallyExpandedItemIDs: Set(timeline.items.map(\.id))
            )
                .padding(20)
                .frame(width: 720, height: 500, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor)),
            size: NSSize(width: 720, height: 500),
            name: "tool-result-json"
        )

        #expect(text.contains("JSON"))
        #expect(text.contains("engine"), "Recognized text: \(text)")
        #expect(text.contains("worker"))
        #expect(!text.contains(#"{"class":"worker""#))
    }

    @Test func nestedToolPreviewFormatsJSONWithoutExpandingItsDetails() async throws {
        let items = [
            PuckTimelineItem(id: "first", role: .tool, content: .tool(PuckToolActivity(
                callID: "first", name: "exec_command", output: "First result", state: .succeeded
            ))),
            PuckTimelineItem(id: "search", role: .tool, content: .tool(PuckToolActivity(
                callID: "search", name: "exec_command",
                arguments: #"{"cmd":"search issues; list changes"}"#,
                output: """
                exit code: 0
                --- stdout ---
                {"error":{"code":"runtime","message":"attempt to write a readonly database"}}
                [{"number":123,"state":"MERGED"}]
                """,
                state: .succeeded
            ))),
        ]

        let text = try await render(
            // Opening the first item exposes the group, leaving the second
            // result in the nested preview state shown in the regression.
            PuckTimelineRows(items: items, initiallyExpandedItemIDs: ["first"])
                .padding(20)
                .frame(width: 800, height: 500, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor)),
            size: NSSize(width: 800, height: 500),
            name: "nested-tool-json-preview"
        )

        let lines = text.components(separatedBy: "\n")
        #expect(text.contains("Ran 2 commands"))
        #expect(lines.contains { $0.contains("runtime") && !$0.contains("readonly") },
                "JSON fields should occupy separate lines: \(text)")
        #expect(lines.contains { $0.contains("readonly database") && !$0.contains("runtime") })
        #expect(text.contains("+5 lines"))
        #expect(!text.contains("ARGUMENTS"))
        #expect(!text.contains("MERGED"))
    }

    @Test func assistantTaggedJSONShowsItsKindAboveTheFormattedPayload() async throws {
        let message = """
        Investigation complete
        [[investigation-result]]
        {"verdict":"needs_more_evidence","confidence":0.91,"root_cause":null}
        [[/investigation-result]]
        More evidence is needed
        """
        let text = try await render(
            PuckTimelineRows(items: [
                PuckTimelineItem(id: "assistant-result", role: .assistant, content: .assistant(message)),
            ])
                .padding(20)
                .frame(width: 900, height: 380, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor)),
            size: NSSize(width: 900, height: 380),
            name: "assistant-tagged-json"
        )

        #expect(text.contains("JSON"))
        #expect(text.contains("investigation-result"))
        #expect(text.contains("confidence"))
        #expect(!text.contains("[["))
        #expect(!text.contains("]]"))
        #expect(text.components(separatedBy: "investigation-result").count == 2)
        #expect(text.components(separatedBy: "\n").contains {
            $0.contains("confidence") && !$0.contains("verdict") && !$0.contains("root_cause")
        })
        #expect(text.contains("Investigation complete"))
        #expect(text.contains("More evidence is needed"))
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

    @Test func questionWizardShowsOnlyTheActiveStep() async throws {
        let daemon = FakePuckDaemon()
        let fixture = try PuckStoreFixture(daemon: daemon)
        let store = fixture.makeStore()
        let question = try PuckPendingQuestion([
            "call_id": "question-1", "expires_at_ms": 0,
            "questions": [
                [
                    "header": "Approach", "question": "How should this be implemented?",
                    "multiple": false, "custom": false,
                    "options": [
                        ["label": "Option one", "description": "Take the direct route."],
                        ["label": "Option two", "description": "Take the careful route."],
                    ],
                ],
                [
                    "header": "Scope", "question": "Which inputs should be supported?",
                    "multiple": false, "custom": false,
                    "options": [["label": "Paste", "description": "Handle pasted content."]],
                ],
            ],
        ])
        let summary = puckSummary(cwd: fixture.project.path, position: "parked", pendingQuestion: question)
        daemon.put(summary)
        store.applyPuckSummaries([summary])
        let session = try #require(store.sessions.first as? PuckSession)

        let text = try await render(
            PuckSessionDetail(session: session)
                .environmentObject(store)
                .background(Color(nsColor: .windowBackgroundColor)),
            size: NSSize(width: 960, height: 640),
            name: "question-wizard-step-1"
        )

        #expect(text.contains("Question 1 of 2"))
        #expect(text.contains("How should this be implemented?"))
        #expect(text.contains("Continue"))
        #expect(!text.contains("Which inputs should be supported?"))
    }

    @Test func arrowKeysWalkThePuckPromptHistory() async throws {
        let daemon = FakePuckDaemon()
        let fixture = try PuckStoreFixture(daemon: daemon)
        let store = fixture.makeStore()
        let summary = puckSummary(cwd: fixture.project.path, position: "idle", historyItems: 2)
        daemon.put(summary, transcript: [
            PuckSessionEvent(cursor: 1, kind: "user_message", text: "First request"),
            PuckSessionEvent(cursor: 2, kind: "user_message", text: "Newest request"),
        ])
        store.applyPuckSummaries([summary])
        let session = try #require(store.sessions.first as? PuckSession)

        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -2_000, y: -2_000), size: NSSize(width: 960, height: 640)),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: PuckSessionDetail(session: session)
            .environmentObject(store)
            .background(Color(nsColor: .windowBackgroundColor)))
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 960, height: 640)
        window.makeKeyAndOrderFront(nil)
        try await waitForPuckState { session.events.count == 2 }
        try await Task.sleep(for: .milliseconds(200))

        try sendKey(NSUpArrowFunctionKey, keyCode: 126, to: window)
        try await waitForPuckState { session.draft == "Newest request" }
        try sendKey(NSUpArrowFunctionKey, keyCode: 126, to: window)
        try await waitForPuckState { session.draft == "First request" }
        try sendKey(NSDownArrowFunctionKey, keyCode: 125, to: window)
        try await waitForPuckState { session.draft == "Newest request" }
        try sendKey(NSDownArrowFunctionKey, keyCode: 125, to: window)
        try await waitForPuckState { session.draft.isEmpty }
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

                > "Some paths are best explored slowly."

                ---

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

        let typography = PuckTranscriptTypography(fontFamily: "Menlo", fontSize: 12)
        let text = try await render(
            VStack(alignment: .leading, spacing: 14) {
                PuckTimelineRows(items: timeline.items, typography: typography)
                PuckTimelineNotices(notices: timeline.notices, typography: typography)
            }
                .padding(20)
                .frame(width: 800, height: 1_250, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor)),
            size: NSSize(width: 800, height: 1_250),
            name: "semantic-collapsed"
        )

        #expect(text.contains("Inspect the parser"))
        #expect(text.contains("Parsed result"))
        #expect(text.contains("Fixed flaky parsing"))
        #expect(text.contains("Parser"))
        #expect(text.contains("Passing"))
        #expect(compactOCR(text).contains("pathsarebestexploredslowly."))
        #expect(!text.contains(">\"Some paths"))
        #expect(!text.contains("> Some paths"))
        #expect(!text.contains("---"))
        #expect(text.contains("let ok = true")
            || (text.contains("let") && text.contains("ok") && text.contains("true")))
        #expect(text.contains("Ran"))
        #expect(text.contains("swift test"))
        #expect(text.contains("All tests passed"))
        #expect(text.contains("Turn error"))
        #expect(text.contains("Provider failed"))
        #expect(text.contains("Turn interrupted"))
        #expect(text.contains("Turn cancelled by user"))
        #expect(text.contains("Unknown event"))
        #expect(text.contains("future_event"))
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

        #expect(text.contains("swift test"))
        #expect(text.contains("All tests passed"))
        #expect(text.contains("Unknown event"))
        #expect(compactOCR(text).contains(compactOCR("new payload")))
        #expect(text.contains("new_flag=true") || text.contains("new_flag-true"))
    }

    @Test func accessibilityIdentifiersCoverTheTranscriptAndDisclosures() {
        #expect(AccessibilityID.puckTimeline == "banyan.puck.timeline")
        #expect(AccessibilityID.puckTimelineItem("call:checks") == "banyan.puck.timeline.item.call:checks")
        #expect(AccessibilityID.puckToolDisclosure("tool:checks") == "banyan.puck.timeline.tool.tool:checks")
        #expect(AccessibilityID.puckToolGroup("tool:checks")
            == "banyan.puck.timeline.tool-group.tool:checks")
        #expect(AccessibilityID.puckUnknownEvent("event:3") == "banyan.puck.timeline.unknown.event:3")
        #expect(AccessibilityID.puckTimelineNotice("notice:error-1")
            == "banyan.puck.timeline.notice.notice:error-1")
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
            // Accurate recognition handles prose, but can omit colored JSON
            // keys entirely. The fast recognizer reads those literal code runs.
            // Both operate on the same rendered pixels, without expected words
            // or spelling substitutions that could hide a rendering regression.
            var recognized: [VNRecognizedTextObservation] = []
            for level: VNRequestTextRecognitionLevel in [.accurate, .fast] {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = level
                request.recognitionLanguages = ["en-US"]
                request.usesLanguageCorrection = level == .accurate
                try VNImageRequestHandler(data: png).perform([request])
                // Add only regions the accurate pass missed. Concatenating both
                // passes duplicates labels; deduplicating by text would instead
                // hide real repeated labels at different positions in the UI.
                let missing = (request.results ?? []).filter { candidate in
                    !recognized.contains { $0.boundingBox.intersects(candidate.boundingBox) }
                }
                recognized += missing
            }
            return recognized.sorted { $0.boundingBox.midY > $1.boundingBox.midY }
                .compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        }.value
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        return view.subviews.lazy.compactMap { firstScrollView(in: $0) }.first
    }
}

private func compactOCR(_ text: String) -> String {
    text.filter { !$0.isWhitespace }
}

@MainActor
private func sendKey(_ functionKey: Int, keyCode: UInt16, to window: NSWindow) throws {
    let characters = String(UnicodeScalar(functionKey)!)
    let event = try #require(NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: keyCode
    ))
    window.sendEvent(event)
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
