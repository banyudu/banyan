import AppKit
import Testing
@testable import SwiftTerm

private final class CursorHierarchyTerminal: TerminalView {
    var hierarchyChanges = 0

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        hierarchyChanges += 1
    }

    override func willRemoveSubview(_ subview: NSView) {
        hierarchyChanges += 1
        super.willRemoveSubview(subview)
    }
}

@Suite @MainActor struct TerminalCursorVisibilityTests {
    @Test func outputCursorTogglesPreserveTheViewHierarchy() throws {
        let view = CursorHierarchyTerminal(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        let caret = try #require(view.caretView)
        view.hierarchyChanges = 0

        // Full-screen agents surround redraws with DEC cursor visibility commands.
        for _ in 0..<100 {
            view.feed(text: "\u{1b}[?25l")
            #expect(caret.isHidden)
            view.feed(text: "\u{1b}[?25h")
            #expect(!caret.isHidden)
        }

        #expect(caret.superview === view)
        #expect(view.hierarchyChanges == 0)
    }

    @Test func cursorVisibilitySurvivesScrollbackAndDisplayRefresh() throws {
        let view = CursorHierarchyTerminal(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        let caret = try #require(view.caretView)
        view.feed(text: (0..<100).map { "line \($0)\r\n" }.joined())
        view.updateCursorPosition()
        #expect(!caret.isHidden)
        view.hierarchyChanges = 0

        view.scrollUp(lines: 30)
        view.updateCursorPosition()
        #expect(caret.isHidden)
        view.scrollDown(lines: 1000)
        view.updateCursorPosition()
        #expect(!caret.isHidden)

        view.feed(text: "\u{1b}[?25l")
        view.updateCursorPosition()
        #expect(caret.isHidden)
        #expect(caret.superview === view)
        #expect(view.hierarchyChanges == 0)
    }

    @Test func rendererSwitchPreservesCursorVisibility() throws {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        let caret = try #require(view.caretView)
        for hidden in [false, true] {
            view.feed(text: hidden ? "\u{1b}[?25l" : "\u{1b}[?25h")
            try view.setUseMetal(true)
            #expect(caret.isHidden)
            try view.setUseMetal(false)
            #expect(caret.isHidden == hidden)
            #expect(caret.superview === view)
        }
    }
}
