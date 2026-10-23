import AppKit
import BanyanCore
import SwiftUI
import Testing
@testable import Banyan

@Suite @MainActor struct SessionParentPickerTests {
    @Test func loadsDestinationsOnceWhileSessionUpdatesContinue() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let host = HostRuntimeContext(environment: ["PATH": "/usr/bin:/bin"],
            homeDirectory: root, currentDirectory: root.path)
        let source = BanyanSession(id: "source", title: "Source", cwd: root.path,
            command: "", status: .needInput, telemetry: banyanTestTelemetry, host: host)
        let parent = BanyanSession(id: "parent", title: "Parent", cwd: root.path,
            command: "", status: .needInput, telemetry: banyanTestTelemetry, host: host)
        var loads = 0
        let picker = SessionParentPicker(session: source, loadTargets: {
            loads += 1
            return [SidebarSessionItem(session: parent, depth: 0)]
        }, move: { _ in Issue.record("Rendering must not move a session") })
        let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 460, height: 480),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = NSHostingView(rootView: picker)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        try await waitForPuckState { loads == 1 }

        // Agent output updates row timestamps while a picker is open. Those
        // redraws must not repeat the catalog/hierarchy query.
        for _ in 0..<10 {
            source.updatedAt = source.updatedAt.addingTimeInterval(2)
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(loads == 1)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        #expect(try #require(bitmap.representation(using: .png, properties: [:])).count > 2000)
    }
}
