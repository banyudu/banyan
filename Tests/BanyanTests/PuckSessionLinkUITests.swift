import AppKit
import BanyanCore
import SwiftUI
import Testing
import Vision
@testable import Banyan

@Suite(.serialized) @MainActor
struct PuckSessionLinkUITests {
    @Test(arguments: ["user", "assistant", "preview", "output", "error", "file"])
    func nativeTextLinksOpenThroughTheSharedResolver(surface: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("puck-links-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("report notes.md")
        try Data().write(to: file)
        let url = "https://example.com/report"
        let cache = GitHubReferenceCache()
        let group = "git:github.com/example/repo"
        let pull = URL(string: "https://github.com/example/repo/pull/123")!
        cache.store(.resolved(pull), groupID: group, number: 123)
        let context = SessionLinkContext(cwd: root.path, environment: [:], homeDirectory: root.path,
                                         repositoryGroupID: group, cache: cache)
        let content: AnyView
        let expected: URL
        let word: String
        switch surface {
        case "user":
            content = AnyView(PuckTimelineRow(item: .init(id: "user", role: .user, content: .user(url)),
                                              isExpanded: .constant(false)))
            expected = URL(string: url)!
            word = "example"
        case "assistant":
            content = AnyView(PuckTimelineRow(item: .init(id: "assistant", role: .assistant, content: .assistant("PR #123")),
                                              isExpanded: .constant(false)))
            expected = pull
            word = "123"
        case "preview":
            let tool = PuckToolActivity(callID: "call", name: "exec_command", output: url, state: .succeeded)
            content = AnyView(PuckTimelineRow(item: .init(id: "tool", role: .tool, content: .tool(tool)),
                                              isExpanded: .constant(false)))
            expected = URL(string: url)!
            word = "example"
        case "output":
            content = AnyView(PuckToolDetailBlock(title: "Output", text: "{\"url\":\"\(url)\"}"))
            expected = URL(string: url)!
            word = "example"
        case "error":
            content = AnyView(PuckTimelineRow(item: .init(id: "error", role: .error, content: .error(url)),
                                              isExpanded: .constant(false)))
            expected = URL(string: url)!
            word = "example"
        default:
            content = AnyView(PuckTimelineRow(item: .init(id: "file", role: .assistant,
                                                         content: .assistant("[Report](report%20notes.md)")),
                                              isExpanded: .constant(false)))
            expected = file
            word = "Report"
        }
        let opened = try await click(word, in: content.sessionLinks(context: context), name: surface)
        #expect(opened == [expected])
    }

    @Test(arguments: [false, true])
    func questionTextAndChoiceLinksUseTheSessionHandler(inChoice: Bool) async throws {
        let daemon = FakePuckDaemon()
        let fixture = try PuckStoreFixture(daemon: daemon)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = fixture.makeStore()
        let url = "https://example.com/report"
        let question = try PuckPendingQuestion([
            "call_id": "question", "expires_at_ms": 0,
            "questions": [[
                "header": "Reference", "question": inChoice ? "Choose an approach" : url,
                "multiple": false, "custom": false,
                "options": [["label": inChoice ? url : "Continue", "description": "Review the reference."]],
            ]],
        ])
        let summary = puckSummary(cwd: fixture.project.path, position: "parked", pendingQuestion: question)
        daemon.put(summary)
        store.openListedPuckSessions([summary])
        let session = try #require(store.sessions.first as? PuckSession)
        let opened = try await click(
            "example", in: PuckSessionDetail(session: session).environmentObject(store),
            name: inChoice ? "question-choice" : "question-stem", size: NSSize(width: 900, height: 650)
        )
        #expect(opened == [URL(string: url)!])
        #expect(daemon.answers.isEmpty)
        session.stopFollowing()
    }

    /// Locate the link in rendered pixels: inline SwiftUI links have no AX
    /// children in the SwiftPM host. The click still travels through AppKit.
    private func click<V: View>(
        _ word: String, in content: V, name: String, size: NSSize = NSSize(width: 820, height: 320)
    ) async throws -> [URL] {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -2_000, y: -2_000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var opened: [URL] = []
        let host = NSHostingView(rootView: content
            .environment(\.openURL, OpenURLAction { opened.append($0); return .handled })
            .padding(20)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
            .preferredColorScheme(.dark))
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BANYAN_PUCK_RENDER_DIR"]
            ?? NSTemporaryDirectory() + "banyan-puck-transcript-ui").appendingPathComponent("link-\(name).png")
        _ = try await VisualSnapshotter.capture(window, to: output.path) { _ in nil }
        let png = try Data(contentsOf: output)
        var bounds: CGRect?
        for level in [VNRequestTextRecognitionLevel.accurate, .fast] {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = level
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(data: png).perform([request])
            for observation in request.results ?? [] {
                guard let candidate = observation.topCandidates(1).first,
                      let range = candidate.string.range(of: word) else { continue }
                bounds = try candidate.boundingBox(for: range)?.boundingBox
                if bounds != nil { break }
            }
            if bounds != nil { break }
        }
        let rect = try #require(bounds, "Could not locate link in \(output.path)")
        let point = NSPoint(x: rect.midX * size.width,
                            y: (host.isFlipped ? 1 - rect.midY : rect.midY) * size.height)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(
                with: type, location: host.convert(point, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
            window.sendEvent(event)
        }
        try await waitForPuckState { !opened.isEmpty }
        return opened
    }
}
