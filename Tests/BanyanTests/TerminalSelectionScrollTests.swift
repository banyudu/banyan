import AppKit
import SwiftTerm
import Testing
@testable import Banyan

/// A selection is stored in buffer-absolute rows. Once the local scrollback is
/// full, every new output line recycles the top line and shifts all remaining
/// content up one absolute row — the selection must follow the text it covers
/// instead of staying at a fixed row and highlighting whatever scrolled into it.
@MainActor
private func makeStreamedTerminal(lines: Int) -> DetectingLocalProcessTerminalView {
    let view = DetectingLocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
    view.changeScrollback(50)
    for index in 0..<lines {
        view.feed(text: "line-\(index)\r\n")
    }
    return view
}

@MainActor
private func selectSecondVisibleLine(of view: DetectingLocalProcessTerminalView) -> String? {
    let row = view.terminal.buffer.yDisp + 1
    view.setSelection(start: Position(col: 0, row: row), end: Position(col: 11, row: row))
    return view.getSelection()
}

@MainActor
@Test func selectionFollowsTextWhenFullScrollbackTrims() {
    // 200 lines overflows the 50-line scrollback, so the buffer is full and
    // every further line trims the top.
    let view = makeStreamedTerminal(lines: 200)
    #expect(view.terminal.buffer.yDisp == 50)
    let selectedText = selectSecondVisibleLine(of: view)
    #expect(selectedText?.contains("line-") == true)

    for index in 0..<5 {
        view.feed(text: "extra-\(index)\r\n")
    }

    #expect(view.selectionActive)
    #expect(view.getSelection() == selectedText)
}

@MainActor
@Test func selectionDeactivatesOnceTrimmedOutOfTheBuffer() {
    let view = makeStreamedTerminal(lines: 200)
    let topRow = view.terminal.buffer.yDisp - 40
    view.setSelection(start: Position(col: 0, row: topRow), end: Position(col: 11, row: topRow))
    #expect(view.selectionActive)

    for index in 0..<60 {
        view.feed(text: "extra-\(index)\r\n")
    }

    #expect(!view.selectionActive)
}

/// tmux scrolls history by repainting the visible rows in place; the reported
/// `#{scroll_position}` delta must shift the selection with the moved content.
@MainActor
@Test func tmuxScrollPositionDeltaShiftsSelection() {
    let view = makeStreamedTerminal(lines: 30)
    let selectedText = selectSecondVisibleLine(of: view)
    let shiftedRowText = view.terminal.getText(
        start: Position(col: 0, row: view.terminal.buffer.yDisp + 4),
        end: Position(col: 11, row: view.terminal.buffer.yDisp + 4)
    )

    // Scrolling up 3 lines repaints every line 3 rows further down, so the
    // selection lands where its text now lives (locally: 3 rows below).
    view.noteTmuxScrollPosition(3)
    #expect(view.getSelection() == shiftedRowText)

    // The same position again is a zero delta and must not move the selection.
    view.noteTmuxScrollPosition(3)
    #expect(view.getSelection() == shiftedRowText)

    // Leaving copy-mode (position 0) restores the original placement.
    view.noteTmuxScrollPosition(0)
    #expect(view.getSelection() == selectedText)
}
