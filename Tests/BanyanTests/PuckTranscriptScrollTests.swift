import AppKit
import Testing
@testable import Banyan

@Suite(.serialized) @MainActor
struct PuckTranscriptScrollTests {
    @Test func geometryDoesNotPublishSwiftUIStateDuringLayout() async throws {
        var changes: [Bool] = []
        let fixture = ScrollFixture { changes.append($0) }

        // refresh() is also called from updateNSView and layout. Publishing here
        // reenters the SwiftUI render that is still updating the transcript.
        fixture.observer.refresh()
        #expect(changes.isEmpty)
        try await waitForPuckState { changes == [false] }
    }

    @Test func geometryBurstPublishesOnlyItsLatestPosition() async throws {
        var changes: [Bool] = []
        let fixture = ScrollFixture { changes.append($0) }
        fixture.observer.refresh()
        try await waitForPuckState { changes == [false] }

        fixture.scroll(to: 480)
        fixture.scroll(to: 0)
        #expect(changes == [false])
        await Task.yield()
        await Task.yield()
        #expect(changes == [false])

        fixture.scroll(to: 480)
        try await waitForPuckState { changes == [false, true] }
    }

    @Test func detachedTranscriptDoesNotDeliverQueuedGeometry() async throws {
        var changes: [Bool] = []
        let fixture = ScrollFixture { changes.append($0) }
        fixture.observer.refresh()
        fixture.observer.stopObserving()
        await Task.yield()
        await Task.yield()
        #expect(changes.isEmpty)

        fixture.observer.refresh()
        try await waitForPuckState { changes == [false] }
    }
}

@MainActor
private struct ScrollFixture {
    let scrollView: NSScrollView
    let observer: PuckTranscriptScrollObserverView

    init(onChange: @escaping @MainActor (Bool) -> Void) {
        _ = NSApplication.shared
        scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
        let document = FlippedDocument(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
        scrollView.documentView = document
        observer = PuckTranscriptScrollObserverView(onChange: onChange)
        document.addSubview(observer)
    }

    func scroll(to y: CGFloat) {
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        observer.refresh()
    }
}

private final class FlippedDocument: NSView {
    override var isFlipped: Bool { true }
}
