import AppKit
import SwiftUI

struct ScratchTerminalWindow: View {
    @EnvironmentObject private var store: SessionStore
    @ObservedObject var session: BanyanSession

    var body: some View {
        TerminalHostView(
            session: session,
            theme: store.terminalTheme,
            fontFamily: store.terminalFontFamily,
            fontSize: store.terminalFontSize,
            focusRequestID: store.scratchTerminalFocusRequestID
        )
        .ignoresSafeArea()
        .frame(minWidth: 520, minHeight: 320)
    }
}

/// Opening geometry for the scratch terminal window.
///
/// Sizing width and height independently from the anchor window let the shape
/// follow whatever the display happened to be: on a wide monitor with the main
/// window maximised, both axes clamped to the screen bounds and the scratch
/// terminal opened at the monitor's aspect ratio (2.44:1 on a 4308pt-wide
/// display). Derive one axis from the other instead so it always opens 16:9.
enum ScratchWindowGeometry {
    static let aspectRatio: CGFloat = 16.0 / 9.0
    /// Fraction of the screen to fill before the absolute bounds apply.
    static let preferredWidthFraction: CGFloat = 0.6
    static let minimumWidth: CGFloat = 880
    /// A scratch terminal gains nothing from being wider than this, however
    /// much room the display has.
    static let maximumWidth: CGFloat = 1_600
    static let screenMargin: CGFloat = 40

    /// A 16:9 window centred on `anchorFrame`, never larger than `visibleFrame`
    /// less a margin, and never positioned outside it.
    static func frame(anchorFrame: CGRect, visibleFrame: CGRect) -> CGRect {
        let availableWidth = max(visibleFrame.width - screenMargin * 2, 1)
        let availableHeight = max(visibleFrame.height - screenMargin * 2, 1)

        var width = min(
            max(visibleFrame.width * preferredWidthFraction, minimumWidth),
            maximumWidth
        )
        width = min(width, availableWidth)
        var height = width / aspectRatio

        // A short screen (or a tall-but-narrow one) drives the size instead.
        if height > availableHeight {
            height = availableHeight
            width = min(height * aspectRatio, availableWidth)
        }

        return CGRect(
            x: clamp(
                anchorFrame.midX - width / 2,
                lower: visibleFrame.minX + screenMargin,
                upper: visibleFrame.maxX - width - screenMargin
            ),
            y: clamp(
                anchorFrame.midY - height / 2,
                lower: visibleFrame.minY + screenMargin,
                upper: visibleFrame.maxY - height - screenMargin
            ),
            width: width,
            height: height
        )
    }

    /// Falls back to `lower` when the window fills the screen, so a window that
    /// cannot fit inside the margins is pinned to the visible frame rather than
    /// pushed off its leading edge.
    private static func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        guard upper > lower else { return lower }
        return min(max(value, lower), upper)
    }
}

final class ScratchTerminalWindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
