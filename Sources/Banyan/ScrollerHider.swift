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
        nsView.hideScrollers()
    }
}

private final class ScrollerHidingView: NSView {
    /// KVO observations keyed weakly: entries vanish with their scroll views,
    /// so replaced instances never pin detached views (or leak them).
    private let observations = NSMapTable<NSScrollView, NSKeyValueObservation>(
        keyOptions: .weakMemory, valueOptions: .strongMemory
    )
    private var windowObserver: NSObjectProtocol?
    private weak var subscribedWindow: NSWindow?
    private var lastFullScan = Date.distantPast
    private static let fullScanInterval: TimeInterval = 0.5

    deinit {
        if let windowObserver {
            NotificationCenter.default.removeObserver(windowObserver)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resubscribeWindow()
        hideScrollers()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        hideScrollers()
    }

    override func layout() {
        super.layout()
        hideScrollers()
    }

    override func viewWillDraw() {
        super.viewWillDraw()
        hideScrollers()
    }

    private func resubscribeWindow() {
        guard window !== subscribedWindow else { return }
        if let windowObserver {
            NotificationCenter.default.removeObserver(windowObserver)
            self.windowObserver = nil
        }
        subscribedWindow = window
        guard let window else { return }
        // SwiftUI can rebuild a List's NSScrollView without any callback
        // firing on this (zero-size background) view, so re-scan on every
        // window display pass (throttled) instead of trusting hooks alone.
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.hideScrollers()
        }
    }

    /// Hides vertical scrollers while keeping trackpad/mouse-wheel scrolling.
    ///
    /// Discovery deliberately does NOT walk up to an "enclosing" scroll view:
    /// live hierarchy inspection (lldb, Sep 2026) proved that `.background()`
    /// on a `List` is hosted *outside* the List's internal NSScrollView —
    /// `ScrollerHidingView → PlatformViewHost → NSHostingView → … →
    /// NSSplitView` with no scroll view in between — so ancestor search always
    /// finds nothing and any fix built on it is a no-op for Lists. Instead, a
    /// mounted hider acts as a beacon: every NSScrollView in the same window
    /// gets its vertical scroller removed, enforced instantly via KVO on
    /// `hasVerticalScroller` plus re-assertion on each display pass (which
    /// also picks up scroll views SwiftUI creates or swaps in later).
    func hideScrollers() {
        reassertKnownScrollViews()
        guard let window, Date().timeIntervalSince(lastFullScan) >= Self.fullScanInterval else { return }
        lastFullScan = Date()
        for scrollView in scrollViews(in: window) {
            conceal(scrollView)
        }
    }

    private func reassertKnownScrollViews() {
        let enumerator = observations.keyEnumerator()
        while let scrollView = enumerator.nextObject() as? NSScrollView {
            if scrollView.hasVerticalScroller {
                scrollView.hasVerticalScroller = false
            }
        }
    }

    private func scrollViews(in window: NSWindow) -> [NSScrollView] {
        guard let contentView = window.contentView else { return [] }
        var found: [NSScrollView] = []
        var stack: [NSView] = [contentView]
        while let view = stack.popLast() {
            if let scrollView = view as? NSScrollView {
                found.append(scrollView)
            }
            stack.append(contentsOf: view.subviews)
        }
        return found
    }

    private func conceal(_ scrollView: NSScrollView) {
        if scrollView.hasVerticalScroller {
            scrollView.hasVerticalScroller = false
        }
        // Weak capture is load-bearing: a strong capture would keep every
        // replaced scroll view (plus observation and closure) alive forever.
        if observations.object(forKey: scrollView) == nil {
            observations.setObject(
                scrollView.observe(\.hasVerticalScroller, options: [.new]) { [weak scrollView] _, change in
                    guard change.newValue == true else { return }
                    DispatchQueue.main.async { [weak scrollView] in
                        if scrollView?.hasVerticalScroller == true {
                            scrollView?.hasVerticalScroller = false
                        }
                    }
                },
                forKey: scrollView
            )
        }
    }
}
