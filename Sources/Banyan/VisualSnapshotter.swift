import AppKit
import Foundation

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
    static func captureMainWindow(to path: String) throws -> URL {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && !$0.isMiniaturized }) else {
            throw SnapshotError.noWindow
        }
        let data = try captureWindow(window) ?? captureContentView(window)
        let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: [.atomic])
        return url
    }

    @MainActor
    private static func captureWindow(_ window: NSWindow) throws -> Data? {
        guard let image = CGWindowListCreateImage(
            .null,
            [.optionIncludingWindow],
            CGWindowID(window.windowNumber),
            [.boundsIgnoreFraming, .bestResolution]
        ) else {
            return nil
        }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw SnapshotError.noPNGData
        }
        return data
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
