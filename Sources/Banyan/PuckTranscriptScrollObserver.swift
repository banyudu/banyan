import AppKit
import BanyanCore
import Foundation
import SwiftUI

/// Grows towards or away from the live end depending on where the reader was
/// before the content grew. This avoids treating an auto-scroll during
/// streaming as the reader leaving the end, while a genuine upward scroll
/// stops following immediately.
enum PuckTranscriptFollowLogic {
    static func shouldFollow(
        previousAtBottom: Bool,
        previousContentMaxY: CGFloat?,
        currentContentMaxY: CGFloat,
        visibleMaxY: CGFloat,
        tolerance: CGFloat = 24
    ) -> Bool {
        let atBottom = currentContentMaxY - visibleMaxY <= tolerance
        if let previousContentMaxY,
           currentContentMaxY > previousContentMaxY + 0.5,
           previousAtBottom {
            return true
        }
        return atBottom
    }
}

struct PuckTranscriptScrollObserver: NSViewRepresentable {
    let onChange: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> PuckTranscriptScrollObserverView {
        PuckTranscriptScrollObserverView(onChange: onChange)
    }

    func updateNSView(_ nsView: PuckTranscriptScrollObserverView, context: Context) {
        nsView.onChange = onChange
        nsView.refresh()
    }

    static func dismantleNSView(_ nsView: PuckTranscriptScrollObserverView, coordinator: ()) {
        nsView.stopObserving()
    }
}

@MainActor
final class PuckTranscriptScrollObserverView: NSView {
    var onChange: @MainActor (Bool) -> Void
    private weak var scrollView: NSScrollView?
    private weak var documentView: NSView?
    private var lastContentMaxY: CGFloat?
    private var wasAtBottom = true
    private var reportedAtBottom = true
    private var pendingReport: Task<Void, Never>?

    init(onChange: @escaping @MainActor (Bool) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        pendingReport?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refresh()
    }

    override func layout() {
        super.layout()
        refresh()
    }

    func refresh() {
        attachIfNeeded()
        evaluate()
    }

    func stopObserving() {
        pendingReport?.cancel()
        pendingReport = nil
        NotificationCenter.default.removeObserver(self)
        scrollView = nil
        documentView = nil
        lastContentMaxY = nil
    }

    private func attachIfNeeded() {
        guard let enclosing = findEnclosingScrollView() else { return }
        guard scrollView !== enclosing || documentView !== enclosing.documentView else { return }

        NotificationCenter.default.removeObserver(self)
        scrollView = enclosing
        documentView = enclosing.documentView
        lastContentMaxY = nil

        enclosing.contentView.postsBoundsChangedNotifications = true
        enclosing.postsFrameChangedNotifications = true
        enclosing.documentView?.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollGeometryChanged),
            name: NSView.boundsDidChangeNotification,
            object: enclosing.contentView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollGeometryChanged),
            name: NSView.frameDidChangeNotification,
            object: enclosing
        )
        if let document = enclosing.documentView {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(scrollGeometryChanged),
                name: NSView.frameDidChangeNotification,
                object: document
            )
        }
    }

    private func findEnclosingScrollView() -> NSScrollView? {
        var candidate = superview
        while let view = candidate {
            if let scrollView = view as? NSScrollView { return scrollView }
            candidate = view.superview
        }
        return nil
    }

    @objc private func scrollGeometryChanged() {
        evaluate()
    }

    private func evaluate() {
        guard let scrollView, let documentView = scrollView.documentView else { return }
        let contentMaxY = documentView.bounds.maxY
        let following = PuckTranscriptFollowLogic.shouldFollow(
            previousAtBottom: wasAtBottom,
            previousContentMaxY: lastContentMaxY,
            currentContentMaxY: contentMaxY,
            visibleMaxY: scrollView.documentVisibleRect.maxY
        )
        lastContentMaxY = contentMaxY
        wasAtBottom = following
        guard following != reportedAtBottom else { return }
        scheduleReport()
    }

    private func scheduleReport() {
        guard pendingReport == nil else { return }
        pendingReport = Task { @MainActor [weak self] in
            // refresh() runs inside updateNSView and layout. Publishing there
            // reenters SwiftUI; transient geometry can also toggle following
            // several times before the same layout pass has finished.
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            self.pendingReport = nil
            guard self.reportedAtBottom != self.wasAtBottom else { return }
            self.reportedAtBottom = self.wasAtBottom
            self.onChange(self.wasAtBottom)
        }
    }
}
