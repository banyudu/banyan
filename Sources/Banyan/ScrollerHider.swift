import SwiftUI
import AppKit

extension View {
    func hidesVerticalScroller() -> some View {
        background(ScrollerHider())
    }
}

private struct ScrollerHider: NSViewRepresentable {
    func makeNSView(context: Context) -> ScrollerHidingView {
        ScrollerHidingView()
    }

    func updateNSView(_ nsView: ScrollerHidingView, context: Context) {}
}

private final class ScrollerHidingView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var current: NSView? = self
            while let view = current {
                if let scrollView = view as? NSScrollView {
                    scrollView.hasVerticalScroller = false
                    scrollView.verticalScroller?.isHidden = true
                    return
                }
                current = view.superview
            }
        }
    }
}
