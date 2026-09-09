import AppKit
@testable import SwiftTerm
import Testing
@testable import Banyan

/// URLs printed as plain text carry no OSC 8 payload, so they are found by scanning
/// the row. The scan has to report the columns the URL actually occupies, because the
/// renderer uses those ranges to decide which cells get the link color.
@MainActor
private func makeTerminalView(width: CGFloat = 800) -> DetectingLocalProcessTerminalView {
    let view = DetectingLocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: width, height: 400))
    view.highlightDetectedLinks = true
    return view
}

/// The text is fed without a newline so it stays on the first buffer row and nothing
/// scrolls, which keeps the expected column ranges readable.
@MainActor
private func detectedRanges(after text: String, in view: DetectingLocalProcessTerminalView) -> [Range<Int>] {
    view.feed(text: text)
    return view.terminal.implicitLinkRowRanges(row: 0)
}

@MainActor
@Test func detectsPlainURLColumnsInsideSurroundingText() {
    let view = makeTerminalView()
    let ranges = detectedRanges(after: "see https://example.com/path now", in: view)

    #expect(ranges == [4..<28])
}

@MainActor
@Test func detectsEveryURLOnTheRow() {
    let view = makeTerminalView()
    let ranges = detectedRanges(after: "a https://one.example b https://two.example", in: view)

    #expect(ranges == [2..<21, 24..<43])
}

@MainActor
@Test func reportsNoRangesForTextWithoutURLs() {
    let view = makeTerminalView()

    #expect(detectedRanges(after: "error: build failed in 12:34", in: view).isEmpty)
}

@MainActor
@Test func linkColorTracksTheTerminalTheme() {
    #expect(TerminalTheme.dark.linkColor != TerminalTheme.light.linkColor)

    let view = makeTerminalView()
    TerminalTheme.dark.apply(to: view)

    #expect(view.linkColor == TerminalTheme.dark.linkColor)
}

/// The rendered run for a detected URL: the theme link color plus the underline that
/// link highlighting already drew.
@MainActor
private func renderedRuns(of view: DetectingLocalProcessTerminalView) -> [(text: String, color: NSColor?, underlined: Bool)] {
    let line = view.terminal.buffer.lines[0]
    let info = view.buildAttributedString(row: 0, line: line, cols: view.terminal.cols)
    var runs: [(text: String, color: NSColor?, underlined: Bool)] = []
    for segment in info.segments {
        let string = segment.attributedString
        string.enumerateAttributes(in: NSRange(location: 0, length: string.length)) { attrs, range, _ in
            runs.append((
                text: (string.string as NSString).substring(with: range),
                color: attrs[.foregroundColor] as? NSColor,
                underlined: attrs[.underlineStyle] != nil
            ))
        }
    }
    return runs
}

@MainActor
@Test func detectedURLRendersInLinkColorAndKeepsItsUnderline() {
    let view = makeTerminalView()
    TerminalTheme.dark.apply(to: view)
    view.feed(text: "see https://example.com/path now")

    let runs = renderedRuns(of: view)
    let link = runs.first { $0.text == "https://example.com/path" }
    #expect(link?.color == TerminalTheme.dark.linkColor)
    #expect(link?.underlined == true)

    let leading = runs.first { $0.text == "see " }
    #expect(leading?.color != TerminalTheme.dark.linkColor)
    #expect(leading?.underlined == false)
}

@MainActor
@Test func urlColoredByTheProgramKeepsThatColor() {
    let view = makeTerminalView()
    TerminalTheme.dark.apply(to: view)
    // SGR 32: the program picked green for the URL itself.
    view.feed(text: "\u{1b}[32mhttps://example.com\u{1b}[0m")

    let link = renderedRuns(of: view).first { $0.text == "https://example.com" }
    #expect(link?.color != TerminalTheme.dark.linkColor)
    #expect(link?.underlined == true)
}

/// Banyan styles its tmux panes with an explicit foreground (`window-style fg=...`),
/// so output arrives painted in the theme's own foreground rather than reporting the
/// default color. That still counts as untouched text and must be recolored.
@MainActor
@Test func urlPaintedInTheThemeForegroundStillGetsTheLinkColor() {
    let view = makeTerminalView()
    TerminalTheme.dark.apply(to: view)
    guard let base = view.defaultForegroundRGB else {
        Issue.record("no resolvable default foreground")
        return
    }
    view.feed(text: "\u{1b}[38;2;\(base.red);\(base.green);\(base.blue)mhttps://example.com/path\u{1b}[0m")

    let link = renderedRuns(of: view).first { $0.text == "https://example.com/path" }
    #expect(link?.color == TerminalTheme.dark.linkColor)
    #expect(link?.underlined == true)
}
