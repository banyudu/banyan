import AppKit
import Foundation
import ScreenCaptureKit

enum VisualSnapshotter {
    enum SnapshotError: LocalizedError {
        case noWindow
        case noContentView
        case noBitmap
        case noPNGData

        var errorDescription: String? {
            switch self {
            case .noWindow:
                return "no Banyan window is available to capture"
            case .noContentView:
                return "the Banyan window has no content view to capture"
            case .noBitmap:
                return "failed to render the Banyan window into a bitmap"
            case .noPNGData:
                return "failed to encode the Banyan window snapshot as PNG"
            }
        }
    }

    @MainActor
    static func captureMainWindow(to path: String) async throws -> URL {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && !$0.isMiniaturized }) else {
            throw SnapshotError.noWindow
        }
        return try await capture(window, to: path)
    }

    @MainActor
    static func capture(
        _ window: NSWindow,
        to path: String,
        windowImage: @MainActor (NSWindow) async throws -> CGImage? = captureWindow
    ) async throws -> URL {
        let data: Data
        if let image = try? await windowImage(window) {
            let bitmap = NSBitmapImageRep(cgImage: image)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw SnapshotError.noPNGData
            }
            data = png
        } else {
            data = try captureContentView(window)
        }
        let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: [.atomic])
        return url
    }

    @MainActor
    private static func captureWindow(_ window: NSWindow) async throws -> CGImage? {
        // Current-process content needs no screen-recording permission. Older
        // systems and unavailable compositor images use our own view bitmap.
        guard #available(macOS 14.4, *) else { return nil }
        let content = try await SCShareableContent.currentProcess
        guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            return nil
        }
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
        configuration.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
        configuration.ignoreShadowsSingleWindow = true
        configuration.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    @MainActor
    private static func captureContentView(_ window: NSWindow) throws -> Data {
        guard let contentView = window.contentView else {
            throw SnapshotError.noContentView
        }

        contentView.layoutSubtreeIfNeeded()
        contentView.displayIfNeeded()

        let bounds = contentView.bounds
        guard let bitmap = contentView.bitmapImageRepForCachingDisplay(in: bounds) else {
            throw SnapshotError.noBitmap
        }
        bitmap.size = bounds.size
        contentView.cacheDisplay(in: bounds, to: bitmap)

        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw SnapshotError.noPNGData
        }
        return data
    }
}
