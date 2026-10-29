import AppKit
import SwiftUI
import Testing
@testable import Banyan

@MainActor
@Suite(.serialized) struct SessionSidebarRevealTests {
    @Test func revealsARowInsertedAndSelectedInTheSameUpdate() async throws {
        let (model, window, _) = try await fixture()
        defer { window.close() }
        model.ids.append("new-session")
        model.selection.selectedSessionID = "new-session"
        try await waitForPuckState { model.fullyVisible("new-session") }
    }

    @Test func retriesWhenTheSelectedRowArrivesLater() async throws {
        let (model, window, _) = try await fixture()
        defer { window.close() }
        model.selection.selectedSessionID = "async-session"
        // Give the first selection update time to run with no matching row.
        try await Task.sleep(for: .milliseconds(100))
        model.ids.append("async-session")
        try await waitForPuckState { model.fullyVisible("async-session") }
    }

    @Test func visibleSelectionsStayInPlaceAndSupersededRequestsDoNotJump() async throws {
        let (model, window, scrollView) = try await fixture()
        defer { window.close() }
        let originalOffset = scrollView.contentView.bounds.origin.y
        model.selection.selectedSessionID = "session-1"
        try await Task.sleep(for: .milliseconds(100))
        #expect(abs(scrollView.contentView.bounds.origin.y - originalOffset) < 1)
        model.selection.selectedSessionID = "session-79"
        model.selection.selectedSessionID = "session-1"
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.fullyVisible("session-1"))
        #expect(abs(scrollView.contentView.bounds.origin.y - originalOffset) < 1)
    }

    @Test func completedRevealDoesNotOverrideManualScrollingWhenOtherRowsArrive() async throws {
        let (model, window, scrollView) = try await fixture()
        defer { window.close() }
        model.selection.selectedSessionID = "session-79"
        try await waitForPuckState { model.fullyVisible("session-79") }
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        try await waitForPuckState { model.fullyVisible("session-1") }
        model.ids.append("background-session")
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.fullyVisible("session-1"))
    }

    private func fixture() async throws -> (RevealListModel, NSWindow, NSScrollView) {
        _ = NSApplication.shared
        let model = RevealListModel()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: RevealListFixture(model: model))
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        try await waitForPuckState { model.fullyVisible("session-1") }
        return (model, window, try #require(firstScrollView(in: host)))
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        return view.subviews.lazy.compactMap { firstScrollView(in: $0) }.first
    }
}

@MainActor
private final class RevealListModel: ObservableObject {
    @Published var ids = (0..<80).map { "session-\($0)" }
    let selection = SessionSelection()
    let shortcuts = SessionJumpShortcuts()
    var geometry = SessionSidebarGeometry()

    func fullyVisible(_ id: String) -> Bool {
        guard let frame = geometry.rows[id], geometry.viewportSize.height > 0 else { return false }
        return frame.minY >= 0 && frame.maxY <= geometry.viewportSize.height
    }
}

private struct RevealListFixture: View {
    @ObservedObject var model: RevealListModel

    var body: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    Text("Project")
                    ForEach(model.ids, id: \.self) { id in
                        Text(id).frame(height: 28).id(id).sessionJumpShortcutRow(id: id)
                    }
                }
            }
            .listStyle(.sidebar)
            .sessionJumpShortcutViewport(shortcuts: model.shortcuts, sessionIDs: model.ids)
            .onPreferenceChange(SessionSidebarGeometryKey.self) { model.geometry = $0 }
            .sessionSidebarReveal(selection: model.selection, sessionIDs: model.ids, proxy: proxy)
        }
    }
}
