import AppKit
import Foundation
import SwiftTerm
final class DetectingLocalProcessTerminalView: LocalProcessTerminalView {
    var onOutput: ((String) -> Void)?
    /// The tmux pane backing this view, so the scroll handler can hand scrollback
    /// off to tmux's copy-mode instead of keeping a duplicate local history.
    var tmuxSessionName: String?
    private var preservedScrollbackTopRow: Int?
    private let displayInvalidationLock = NSLock()
    private var displayInvalidationPending = false

    /// SwiftTerm requests a full surface repaint for terminal input. Agent
    /// output can arrive in many small PTY chunks, so forwarding every request
    /// directly to AppKit creates a repaint storm and keeps the main thread in
    /// `drawTerminalContents` indefinitely. Coalesce invalidations to one per
    /// main-run-loop turn; terminal state is still fed for every chunk.
    override func setNeedsDisplay(_ invalidRect: NSRect) {
        displayInvalidationLock.lock()
        guard !displayInvalidationPending else {
            displayInvalidationLock.unlock()
            return
        }
        displayInvalidationPending = true
        displayInvalidationLock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.flushCoalescedDisplayInvalidation()
        }
    }

    private func flushCoalescedDisplayInvalidation() {
        displayInvalidationLock.lock()
        displayInvalidationPending = false
        displayInvalidationLock.unlock()
        super.setNeedsDisplay(bounds)
    }

    var hasVisibleText: Bool {
        let dimensions = terminal.getDims()
        guard dimensions.cols > 0, dimensions.rows > 0 else { return false }
        for row in 0..<dimensions.rows {
            for col in 0..<dimensions.cols {
                guard let character = terminal.getCharacter(col: col, row: row) else { continue }
                if String(character).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                    return true
                }
            }
        }
        return false
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureInteraction()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureInteraction()
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        let preservedTopRow = preservedScrollbackTopRow ?? (canScroll && scrollPosition < 1 ? terminal.buffer.yDisp : nil)
        if let text = String(bytes: slice, encoding: .utf8) {
            onOutput?(text)
        }
        super.dataReceived(slice: TerminalFooterLinkifier.annotate(slice))
        if let preservedTopRow {
            restoreScrollbackPosition(preservedTopRow)
        }
    }

    func noteUserScrollbackPosition() {
        guard canScroll, scrollPosition < 1 else {
            preservedScrollbackTopRow = nil
            return
        }
        preservedScrollbackTopRow = terminal.buffer.yDisp
    }

    func preserveScrollPosition() {
        guard canScroll, scrollPosition < 1 else { return }
        preservedScrollbackTopRow = terminal.buffer.yDisp
    }

    func resetForNewProcess(preserveScrollPosition: Bool = false) {
        let preservedTopRow = preserveScrollPosition ? preservedScrollbackTopRow : nil
        preservedScrollbackTopRow = preservedTopRow
        terminal.resetToInitialState()
        needsDisplay = true
        setNeedsDisplay(bounds)
    }

    func refreshLinkTracking() {
        // SwiftTerm creates its tracking area when linkHighlightMode changes.
        // At terminal construction time the view has a zero-sized frame; repeat
        // the assignment after layout so hover links track the real terminal.
        linkHighlightMode = .hoverWithModifier
    }

    private func restoreScrollbackPosition(_ row: Int) {
        guard canScroll else { return }
        scrollTo(row: row, notifyAccessibility: false)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.canScroll else { return }
            self.scrollTo(row: row, notifyAccessibility: false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            guard let self, self.canScroll else { return }
            self.scrollTo(row: row, notifyAccessibility: false)
        }
    }

    private func configureInteraction() {
        // tmux owns this pane's history (see `TmuxBackend.scrollHistory`), so the
        // local buffer only has to cover what tmux repaints plus a little slack —
        // it is no longer the scrollback of record.
        //
        // The old 20_000 mirrored tmux's `history-limit`, which meant carrying a
        // second copy of the same history in a far costlier representation:
        // `BufferLine` allocates a dense `cols`-wide `CharData` array per line and
        // fills every cell, so a line costs ~6 KB whether it holds text or not, and
        // the count tracks the configured limit rather than actual content. That was
        // ~118 MB per terminal against ~35 MB for tmux's whole server.
        changeScrollback(1_000)
        allowMouseReporting = false
    }
}
