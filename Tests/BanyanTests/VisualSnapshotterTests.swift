import AppKit
import Foundation
import Testing
@testable import Banyan

@Suite(.serialized) @MainActor
struct VisualSnapshotterTests {
    @Test(arguments: [false, true])
    func unavailableCompositorFallsBackToOwnView(throwsError: Bool) async throws {
        let fixture = SnapshotFixture()
        defer { fixture.cleanUp() }
        let url = try await VisualSnapshotter.capture(fixture.window, to: fixture.output.path) { _ in
            if throwsError { throw SnapshotFixture.Error.unavailable }
            return nil
        }
        #expect(url == fixture.output)
        let bitmap = try #require(NSBitmapImageRep(data: Data(contentsOf: url)))
        #expect(bitmap.pixelsWide >= 120 && bitmap.pixelsHigh >= 80)
        let color = try #require(bitmap.colorAt(x: 10, y: 10)?.usingColorSpace(.sRGB))
        // Window bitmaps carry the display profile, so test the blue content
        // rather than assuming its converted RGB components are exactly 0/1.
        #expect(color.blueComponent - color.redComponent > 0.5, "Captured pixel: \(color)")
    }

    @Test func compositorImageIsEncodedWithoutReplacingItWithTheFallback() async throws {
        let fixture = SnapshotFixture()
        defer { fixture.cleanUp() }
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: 4, height: 3, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 3))
        let image = try #require(context.makeImage())
        let url = try await VisualSnapshotter.capture(fixture.window, to: fixture.output.path) { _ in image }
        let captured = try #require(NSBitmapImageRep(data: Data(contentsOf: url)))
        #expect(captured.pixelsWide == 4 && captured.pixelsHigh == 3)
        let color = try #require(captured.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB))
        #expect(color.redComponent > 0.9 && color.blueComponent < 0.1, "Captured pixel: \(color)")
    }

    @Test func currentProcessCaptureWritesAPNGWithoutRequestingScreenAccess() async throws {
        let fixture = SnapshotFixture()
        defer { fixture.cleanUp() }
        // An offscreen, unshown window may be absent from ScreenCaptureKit;
        // the public capture path must still render it through the fallback.
        let url = try await VisualSnapshotter.capture(fixture.window, to: fixture.output.path)
        #expect(NSBitmapImageRep(data: try Data(contentsOf: url)) != nil)
    }
}

@MainActor
private struct SnapshotFixture {
    enum Error: Swift.Error { case unavailable }
    let window: NSWindow
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("snapshot-\(UUID())")
    var output: URL { root.appendingPathComponent("nested/window.png") }

    init() {
        _ = NSApplication.shared
        window = NSWindow(contentRect: NSRect(x: -2_000, y: -2_000, width: 120, height: 80),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = BlueSnapshotView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
    }

    func cleanUp() {
        window.close()
        try? FileManager.default.removeItem(at: root)
    }
}

private final class BlueSnapshotView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.blue.setFill()
        bounds.fill()
    }
}
