import AppKit
import ImageIO
import SwiftUI

/// Downsampled previews of attached images, decoded off the main thread and
/// cached by path so a long transcript does not hold full-size bitmaps.
enum PuckImageThumbnailCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 128
        return cache
    }()

    static func cached(_ path: String) -> NSImage? {
        cache.object(forKey: path as NSString)
    }

    static func load(_ path: String, maxPixelSize: Int) async -> NSImage? {
        if let image = cached(path) { return image }
        let image = await Task.detached(priority: .utility) { () -> NSImage? in
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            ]
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
        }.value
        if let image { cache.setObject(image, forKey: path as NSString) }
        return image
    }
}

struct PuckImageThumbnail: View {
    let path: String
    var height: CGFloat = 96
    /// The placeholder number the message text uses for this image.
    var label: String?
    var onRemove: (() -> Void)?
    @State private var image: NSImage?
    @State private var missing = false

    /// Paths that are not absolute files name an image the engine kept only
    /// inline; there is nothing to preview or open.
    private var isFile: Bool { path.hasPrefix("/") }

    var body: some View {
        Button {
            guard isFile else { return }
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        } label: {
            preview
                .frame(height: height)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                }
        }
        .buttonStyle(.banyanPlainLabelOnly)
        .overlay(alignment: .bottomLeading) {
            if let label {
                Text(label)
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(4)
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .topTrailing) {
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.6))
                        .font(.system(size: 14))
                }
                .buttonStyle(.banyanPlainLabelOnly)
                .padding(3)
                .help("Remove this image")
                .accessibilityLabel("Remove image \((path as NSString).lastPathComponent)")
            }
        }
        .help(isFile ? (path as NSString).lastPathComponent : "Attached image")
        .accessibilityLabel(label.map { "Image \($0), \((path as NSString).lastPathComponent)" }
            ?? "Image \((path as NSString).lastPathComponent)")
        .task(id: path) {
            guard isFile else { missing = true; return }
            image = PuckImageThumbnailCache.cached(path)
            guard image == nil else { return }
            image = await PuckImageThumbnailCache.load(path, maxPixelSize: Int(height * 3))
            missing = image == nil
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            ZStack {
                Color.primary.opacity(0.06)
                Image(systemName: missing ? "photo.badge.exclamationmark" : "photo")
                    .foregroundStyle(.secondary)
            }
            .aspectRatio(4 / 3, contentMode: .fit)
        }
    }
}

struct PuckImageThumbnailStrip: View {
    let paths: [String]
    /// One label per path, or none.
    var labels: [String]?
    var height: CGFloat = 96
    var onRemove: ((Int) -> Void)?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Array(paths.enumerated()), id: \.offset) { index, path in
                    PuckImageThumbnail(
                        path: path,
                        height: height,
                        label: labels.flatMap { $0.indices.contains(index) ? $0[index] : nil },
                        onRemove: onRemove.map { remove in { remove(index) } }
                    )
                }
            }
        }
        .scrollIndicators(.never)
        .frame(height: height)
    }
}
