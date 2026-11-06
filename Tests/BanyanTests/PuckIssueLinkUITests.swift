import AppKit
import BanyanCore
import SwiftUI
import Testing
@testable import Banyan

@Suite(.serialized) @MainActor
struct PuckIssueLinkUITests {
    @Test func assistantIssueLinkOpensItsConfiguredDestination() async throws {
        _ = NSApplication.shared
        let size = NSSize(width: 820, height: 320)
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -2_000, y: -2_000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var openedURLs: [URL] = []
        let content = PuckTimelineRows(items: [
            PuckTimelineItem(id: "assistant-1", role: .assistant, content: .assistant("""
            TASK-123 — 已找到既有工单，正在核对证据。

            - Related: **TASK-456** and `task-789`.
            - Existing: [TASK-234](https://example.com/original).

            ```text
            TASK-999 stays literal in a code block.
            ```
            """)),
        ])
        .environment(\.markdownLinkEnvironment, ["BANYAN_LINEAR_ORG": "example"])
        .environment(\.openURL, OpenURLAction { url in
            openedURLs.append(url)
            return .handled
        })
        .padding(20)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
        let host = NSHostingView(rootView: content)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()

        // Click inside the first word of this fixed-size fixture. SwiftUI's
        // inline text links do not expose AX children in the SwiftPM test host.
        let point = NSPoint(x: 60, y: host.isFlipped ? 27 : size.height - 27)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(
                with: type, location: host.convert(point, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
            window.sendEvent(event)
        }
        #expect(openedURLs.map(\.absoluteString) == ["https://linear.app/example/issue/TASK-123"])

        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BANYAN_PUCK_RENDER_DIR"]
            ?? NSTemporaryDirectory() + "banyan-puck-transcript-ui")
            .appendingPathComponent("issue-links.png")
        _ = try await VisualSnapshotter.capture(window, to: output.path) { _ in nil }
    }
}
