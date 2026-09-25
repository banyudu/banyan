import AppKit
@testable import SwiftTerm
import Testing
@testable import Banyan

/// Streaming agent output arrives as many small PTY chunks. What matters for energy
/// is how many repaints — and how much CoreText rebuilding — that stream costs, not
/// how many chunks arrive. These tests pin that ratio against a fixed workload.

@MainActor
private final class StreamingHarness {
    let window: NSWindow
    let view: DetectingLocalProcessTerminalView

    init(cols: Int = 200, rows: Int = 50) {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let size = NSSize(width: font.maximumAdvancement.width * CGFloat(cols), height: 16 * CGFloat(rows))
        view = DetectingLocalProcessTerminalView(frame: NSRect(origin: .zero, size: size))
        view.highlightDetectedLinks = true
        // A headless test process never reports its window as visible, which would
        // otherwise make every flush drop its invalidation.
        view.surfaceVisibilityOverride = { true }
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView?.addSubview(view)
        window.orderFront(nil)
    }

    /// Feed one PTY chunk exactly as `LocalProcess` would.
    func feedChunk(_ text: String) {
        view.dataReceived(slice: ArraySlice(Array(text.utf8)))
    }

    /// Yield so SwiftTerm's 60Hz display queue and the coalescing flush can run,
    /// then paint whatever they invalidated.
    func settle(milliseconds: Int = 40) async throws {
        try await Task.sleep(for: .milliseconds(milliseconds))
        view.displayIfNeeded()
    }

    /// Drive a whole stream the way PTY reads actually arrive: a chunk, then a turn
    /// of the main queue, repeatedly.
    func stream(_ chunks: [String]) async throws {
        for chunk in chunks {
            feedChunk(chunk)
            try await Task.sleep(for: .milliseconds(1))
            view.displayIfNeeded()
        }
        try await Task.sleep(for: .milliseconds(120))
        view.displayIfNeeded()
    }
}

/// A representative agent stream: mostly short appends to the bottom row, a newline
/// every few chunks, with a URL so link detection is exercised on the hot path.
private func streamingChunks(count: Int) -> [String] {
    (0..<count).map { index in
        index % 6 == 5 ? "  ok https://example.com/build/\(index)\r\n" : "step \(index) "
    }
}

@MainActor
@Test func streamingOutputCoalescesIntoFarFewerRepaintsThanChunks() async throws {
    let harness = StreamingHarness()
    try await harness.settle()
    harness.view.resetDrawAccounting()

    let chunks = streamingChunks(count: 600)
    try await harness.stream(chunks)

    let drawCount = harness.view.drawCount
    print("BENCH chunks=\(chunks.count) draws=\(drawCount)"
          + " rowsRebuilt=\(harness.view.drawnRowsRebuilt)"
          + " totalDrawMS=\(String(format: "%.1f", harness.view.totalDrawMS))")

    #expect(drawCount > 0)
    #expect(drawCount < chunks.count / 2)
}

@MainActor
@Test func steadyStreamingRebuildsOnlyTheRowsThatChanged() async throws {
    let harness = StreamingHarness()
    try await harness.settle()
    harness.view.resetDrawAccounting()

    try await harness.stream(streamingChunks(count: 300))

    let draws = max(harness.view.drawCount, 1)
    let rowsPerDraw = Double(harness.view.drawnRowsRebuilt) / Double(draws)
    print("BENCH rowsRebuiltPerDraw=\(String(format: "%.1f", rowsPerDraw)) draws=\(draws)")

    #expect(rowsPerDraw < 10)
}

/// What a coding-agent TUI actually does: home the cursor and rewrite the whole
/// visible frame on every tick. Only the spinner and the counter differ between
/// frames — the rest of the screen is re-sent byte-identical. This is the workload
/// behind the expensive `terminal.draw` samples, not plain appends.
private func fullFrameRepaints(frames: Int, rows: Int, cols: Int) -> [String] {
    let spinner = Array("|/-\\")
    return (0..<frames).map { frame in
        var out = ""
        for row in 0..<rows {
            let body: String
            if row == 0 {
                body = "\(spinner[frame % spinner.count]) working  \(frame * 37) tokens"
            } else {
                body = "row \(row) is a stable line of agent output "
            }
            let filler = String(repeating: "abcdef ", count: max(0, (cols - body.count - 1) / 7))
            // Absolute positioning, no newlines: a pane repaint must not scroll.
            out += "\u{1b}[\(row + 1);1H\u{1b}[2K" + body + filler
        }
        return out
    }
}

@MainActor
@Test func unchangedRowsSurviveAFullFrameRepaint() async throws {
    let harness = StreamingHarness()
    let dims = harness.view.terminal.getDims()
    // Paint one frame first so every row is cached before measuring.
    try await harness.stream(fullFrameRepaints(frames: 1, rows: dims.rows, cols: dims.cols))
    try await harness.settle()
    harness.view.resetDrawAccounting()

    let frames = 60
    try await harness.stream(fullFrameRepaints(frames: frames, rows: dims.rows, cols: dims.cols))

    let draws = max(harness.view.drawCount, 1)
    let rowsPerDraw = Double(harness.view.drawnRowsRebuilt) / Double(draws)
    print("BENCH fullframe frames=\(frames) draws=\(draws)"
          + " rowsRebuilt=\(harness.view.drawnRowsRebuilt)"
          + " rowsPerDraw=\(String(format: "%.1f", rowsPerDraw))"
          + " totalDrawMS=\(String(format: "%.1f", harness.view.totalDrawMS))"
          + " msPerDraw=\(String(format: "%.2f", harness.view.totalDrawMS / Double(draws)))")

    // Only the spinner row changes, so a repaint must not rebuild the viewport.
    #expect(rowsPerDraw < 5)
}

/// A pane repaint that changes nothing — tmux re-sending an identical screen on a
/// status tick, or a spinner that happens to land on the same frame — must not cost
/// a wakeup and a repaint. This is the invalidation half of the same idea that
/// `unchangedRowsSurviveAFullFrameRepaint` covers for the rebuild half.
@MainActor
@Test func identicalRepaintsDoNotInvalidateAtAll() async throws {
    let harness = StreamingHarness()
    let dims = harness.view.terminal.getDims()
    let frame = fullFrameRepaints(frames: 1, rows: dims.rows, cols: dims.cols)[0]

    try await harness.stream([frame])
    try await harness.settle()
    harness.view.resetDrawAccounting()

    // Re-send the very same frame 40 times.
    try await harness.stream(Array(repeating: frame, count: 160))

    print("BENCH identicalRepaint draws=\(harness.view.drawCount)"
          + " totalDrawMS=\(String(format: "%.1f", harness.view.totalDrawMS))")
    // One settling repaint can still be in flight when the measurement starts; what
    // matters is that the remaining 159 identical frames add nothing.
    #expect(harness.view.drawCount <= 1)
}

/// The content filter must never swallow a repaint whose reason lives outside the
/// buffer. Changing the theme leaves every cell identical but every pixel different.
@MainActor
@Test func forcedRepaintSurvivesTheContentFilter() async throws {
    let harness = StreamingHarness()
    let dims = harness.view.terminal.getDims()
    try await harness.stream(fullFrameRepaints(frames: 1, rows: dims.rows, cols: dims.cols))
    try await harness.settle()
    harness.view.resetDrawAccounting()

    harness.view.nativeForegroundColor = NSColor.systemPink
    try await harness.settle(milliseconds: 120)

    #expect(harness.view.drawCount > 0)
}

/// `visiblyChangedRows` is the filter that decides whether a repaint happens at all.
/// These pin its contract directly, because an end-to-end draw count can be satisfied
/// by some other invalidation path and would not notice the filter misbehaving.

@MainActor
@Test func visiblyChangedRowsReportsNothingWhenContentIsUnchanged() async throws {
    let harness = StreamingHarness()
    let dims = harness.view.terminal.getDims()
    try await harness.stream(fullFrameRepaints(frames: 1, rows: dims.rows, cols: dims.cols))
    try await harness.settle()

    // First pass records the hashes, second pass sees the same content.
    _ = harness.view.visiblyChangedRows(from: 0, to: dims.rows - 1, forced: false)
    #expect(harness.view.visiblyChangedRows(from: 0, to: dims.rows - 1, forced: false) == nil)
}

@MainActor
@Test func visiblyChangedRowsNarrowsToTheRowThatMoved() async throws {
    let harness = StreamingHarness()
    let dims = harness.view.terminal.getDims()
    try await harness.stream(fullFrameRepaints(frames: 1, rows: dims.rows, cols: dims.cols))
    try await harness.settle()
    _ = harness.view.visiblyChangedRows(from: 0, to: dims.rows - 1, forced: false)

    harness.feedChunk("\u{1b}[4;1H\u{1b}[2Kchanged")

    let range = harness.view.visiblyChangedRows(from: 0, to: dims.rows - 1, forced: false)
    #expect(range?.0 == 3)
    #expect(range?.1 == 3)
}

@MainActor
@Test func visiblyChangedRowsHonorsAForcedRepaint() async throws {
    let harness = StreamingHarness()
    let dims = harness.view.terminal.getDims()
    try await harness.stream(fullFrameRepaints(frames: 1, rows: dims.rows, cols: dims.cols))
    try await harness.settle()
    _ = harness.view.visiblyChangedRows(from: 0, to: dims.rows - 1, forced: false)

    let range = harness.view.visiblyChangedRows(from: 0, to: dims.rows - 1, forced: true)
    #expect(range?.0 == 0)
    #expect(range?.1 == dims.rows - 1)
}

/// Row indices address the normal and alternate buffers independently, so hashes
/// recorded against one must never satisfy a repaint of the other.
@MainActor
@Test func visiblyChangedRowsDoesNotCarryHashesAcrossAScreenSwitch() async throws {
    let harness = StreamingHarness()
    let dims = harness.view.terminal.getDims()
    let frame = fullFrameRepaints(frames: 1, rows: dims.rows, cols: dims.cols)[0]
    try await harness.stream([frame])
    try await harness.settle()
    _ = harness.view.visiblyChangedRows(from: 0, to: dims.rows - 1, forced: false)

    // Enter the alternate screen and paint the byte-identical frame into it.
    harness.feedChunk("\u{1b}[?1049h" + frame)
    try await harness.settle()

    #expect(harness.view.visiblyChangedRows(from: 0, to: dims.rows - 1, forced: false) != nil)
}

/// Hover highlighting changes how a row draws without changing any cell, so it has
/// to bypass the content filter.
@MainActor
@Test func linkHoverHighlightBypassesTheContentFilter() async throws {
    let harness = StreamingHarness()
    try await harness.stream(["visit https://example.com/hover now"])
    try await harness.settle()
    _ = harness.view.visiblyChangedRows(from: 0, to: harness.view.terminal.getDims().rows - 1, forced: false)

    harness.view.invalidateLinkHighlightRow(harness.view.terminal.buffer.yDisp)

    #expect(harness.view.pendingRenderOnlyInvalidation)
}

/// The half-duty cap: spacing math is pure wall-clock arithmetic, pinned here
/// without depending on real draw timing.
@Test func coalesceDelayIsZeroForFastOrStaleDraws() {
    // Fast draws never space: single keystroke echoes stay immediate.
    #expect(DetectingLocalProcessTerminalView.coalesceDelay(now: 100, lastDrawMS: 5, lastDrawUptime: 99.9) == 0)
    // A slow draw long past earns no spacing either.
    #expect(DetectingLocalProcessTerminalView.coalesceDelay(now: 100, lastDrawMS: 25, lastDrawUptime: 90) == 0)
}

@Test func coalesceDelayBoundsDrawsToHalfDuty() {
    // A 25ms draw earns a 50ms spacing; 10ms after it, 40ms remain.
    let delay = DetectingLocalProcessTerminalView.coalesceDelay(now: 100.01, lastDrawMS: 25, lastDrawUptime: 100)
    #expect(abs(delay - 0.04) < 0.005)
    // Floor is ~30fps even for barely-slow draws.
    let floor = DetectingLocalProcessTerminalView.coalesceDelay(now: 100, lastDrawMS: 13, lastDrawUptime: 100)
    #expect(abs(floor - (1.0 / 30.0)) < 0.005)
    // The old 100ms cap let a 500ms draw occupy 83% of a sustained stream.
    let expensive = DetectingLocalProcessTerminalView.coalesceDelay(now: 100, lastDrawMS: 500, lastDrawUptime: 100)
    #expect(abs(expensive - 0.5) < 0.005)
    let observed = DetectingLocalProcessTerminalView.coalesceDelay(now: 100, lastDrawMS: 235, lastDrawUptime: 100)
    #expect(abs(observed - 0.235) < 0.005)
}
