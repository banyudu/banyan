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

    func updateNSView(_ nsView: ScrollerHidingView, context: Context) {
        nsView.hideEnclosingScroller()
    }
}

private final class ScrollerHidingView: NSView {
    private var observedScrollViews: [ObjectIdentifier: NSScrollView] = [:]
    private var scrollerObservations: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private var discoveryAttempts = 0
    private static let maxDiscoveryAttempts = 20

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hideEnclosingScroller()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        hideEnclosingScroller()
    }

    override func layout() {
        super.layout()
        hideEnclosingScroller()
    }

    override func viewWillDraw() {
        super.viewWillDraw()
        hideEnclosingScroller()
    }

    /// SwiftUI reconfigures the enclosing NSScrollView on state updates, which
    /// restores `hasVerticalScroller` and brings the scrollbar back. A one-shot
    /// hide is not enough — and layout/draw hooks rarely fire on a zero-size
    /// background view — so enforcement is event-driven: KVO catches the exact
    /// mutation that re-enables the scroller. Trackpad/mouse-wheel scrolling
    /// keeps working; only the visible bar stays gone.
    ///
    /// Every trigger re-walks the live ancestor chain instead of trusting the
    /// cache: SwiftUI can swap in a replacement scroll view instance (e.g. when
    /// a ScrollViewReader attaches or state reconfigures the list) while the
    /// old instance stays alive, which would otherwise pin the cache to a
    /// detached view while its replacement shows a bar. All ancestors are
    /// hidden, not just the nearest, so nested scroll views are covered too.
    func hideEnclosingScroller() {
        let scrollViews = findAncestorScrollViews()
        guard !scrollViews.isEmpty else {
            scheduleDiscoveryRetry()
            return
        }
        discoveryAttempts = 0
        let currentIDs = Set(scrollViews.map { ObjectIdentifier($0) })
        for id in observedScrollViews.keys where !currentIDs.contains(id) {
            scrollerObservations[id]?.invalidate()
            scrollerObservations.removeValue(forKey: id)
            observedScrollViews.removeValue(forKey: id)
        }
        for scrollView in scrollViews {
            Self.setScrollerHidden(on: scrollView)
            let id = ObjectIdentifier(scrollView)
            guard scrollerObservations[id] == nil else { continue }
            observedScrollViews[id] = scrollView
            scrollerObservations[id] = scrollView.observe(
                \.hasVerticalScroller,
                options: [.new]
            ) { scrollView, change in
                guard change.newValue == true else { return }
                DispatchQueue.main.async { [weak scrollView] in
                    guard let scrollView else { return }
                    Self.setScrollerHidden(on: scrollView)
                }
            }
        }
    }

    private static func setScrollerHidden(on scrollView: NSScrollView) {
        if scrollView.hasVerticalScroller {
            scrollView.hasVerticalScroller = false
        }
        if scrollView.verticalScroller?.isHidden == false {
            scrollView.verticalScroller?.isHidden = true
        }
    }

    private func findAncestorScrollViews() -> [NSScrollView] {
        var found: [NSScrollView] = []
        var current: NSView? = self
        while let view = current {
            if let scrollView = view as? NSScrollView {
                found.append(scrollView)
            }
            current = view.superview
        }
        return found
    }

    /// The enclosing scroll view may not exist yet while SwiftUI is still
    /// assembling the hierarchy; retry with bounded backoff until found.
    /// Replacement instances are handled by reconciling the live ancestor
    /// chain on every trigger (see above), so no retry is needed once
    /// anything is observed.
    private func scheduleDiscoveryRetry() {
        guard window != nil, observedScrollViews.isEmpty else { return }
        guard discoveryAttempts < Self.maxDiscoveryAttempts else { return }
        discoveryAttempts += 1
        let delay = min(0.1 * Double(discoveryAttempts), 1.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.observedScrollViews.isEmpty, self.window != nil else { return }
            self.hideEnclosingScroller()
        }
    }
}
