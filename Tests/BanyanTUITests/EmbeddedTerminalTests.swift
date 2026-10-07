import BanyanCore
import Foundation
import Testing
@testable import BanyanTUI

private let layout = TerminalLayout(columns: 100, rows: 30)

@Test func embeddedInputPreservesUTF8ControlsAndFragmentedSequences() {
    var router = TerminalInputRouter()
    let bytes = Array("héllo 世界\r".utf8) + [3, 4, 9, 127]
    #expect(router.consume(bytes, layout: layout, mouseEnabled: false) == [.bytes(bytes)])
    #expect(router.consume([27, 91], layout: layout, mouseEnabled: false).isEmpty)
    #expect(router.consume([65], layout: layout, mouseEnabled: false) == [.bytes([27, 91, 65])])
    #expect(router.consume([27], layout: layout, mouseEnabled: false).isEmpty)
    #expect(router.flushEscape() == [27])
    #expect(router.consume([2, 91], layout: layout, mouseEnabled: false) == [.bytes([2, 91])])
}

@Test func embeddedPrefixAndPasteCannotTriggerAccidentalNavigation() {
    var router = TerminalInputRouter()
    #expect(router.consume([29], layout: layout, mouseEnabled: false).isEmpty)
    #expect(router.consume([106, 29, 107, 29, 93, 29, 29], layout: layout, mouseEnabled: false)
            == [.next, .previous, .sidebar, .bytes([29])])
    let paste = Array("\u{1b}[200~a\u{1d}j\u{1d}]\r\u{1b}[201~".utf8)
    #expect(router.consume(paste, layout: layout, mouseEnabled: false) == [.bytes(paste)])
    #expect(router.consume(paste, layout: layout, mouseEnabled: false, bracketedPaste: false)
            == [.bytes(Array("a\u{1d}j\u{1d}]\r".utf8))])
}

@Test func embeddedMouseReportsTranslateToPaneCoordinatesAndExcludeSidebar() {
    var router = TerminalInputRouter()
    let report = Array("\u{1b}[<0;\(layout.terminalColumn + 2);\(layout.terminalRow + 1)M".utf8)
    #expect(router.consume(Array(report.prefix(5)), layout: layout, mouseEnabled: true).isEmpty)
    #expect(router.consume(Array(report.dropFirst(5)), layout: layout, mouseEnabled: true)
            == [.bytes(Array("\u{1b}[<0;3;2M".utf8))])
    #expect(router.consume(Array("\u{1b}[<0;2;4M".utf8), layout: layout, mouseEnabled: true).isEmpty)
    #expect(router.consume(report, layout: layout, mouseEnabled: false).isEmpty)
}

@Test func swiftTermGridParsesUTF8AttributesCursorAndAlternateScreen() {
    let model = TerminalGridModel(columns: 12, rows: 4)
    let bytes = Array("\u{1b}[31;1m你é\u{1b}[0m".utf8)
    bytes.forEach { model.feed([$0]) }
    var snapshot = model.snapshot()
    #expect(snapshot.lines[0].contains("你é"))
    #expect(snapshot.lines[0].contains("38;5;1"))
    #expect(snapshot.lines[0].contains(";1;"))
    #expect(snapshot.cursorColumn == 3)
    model.feed(Array("\u{1b}[?1049h\u{1b}[2J\u{1b}[HALT\u{1b}[?25l\u{1b}[6 q".utf8))
    snapshot = model.snapshot()
    #expect(snapshot.lines[0].contains("ALT"))
    #expect(!snapshot.cursorVisible)
    #expect(snapshot.cursorStyle == 6)
    model.feed(Array("\u{1b}[?1049l\u{1b}[?25h".utf8))
    #expect(model.snapshot().lines[0].contains("你é"))
    #expect(model.snapshot().cursorVisible)
    #expect(TerminalGridModel.padded("你é\u{1b}\n", width: 5) == "你é  ")
}

@Test func swiftTermGridHandlesScrollbackResizeAndTerminalReplies() {
    let model = TerminalGridModel(columns: 20, rows: 3)
    var replies: [UInt8] = []
    model.reply = { replies += $0 }
    model.feed(Array("first\r\nsecond\r\nthird\r\nfourth\u{1b}[6n".utf8))
    #expect(model.terminal.getBufferAsData().contains(Data("first".utf8)))
    #expect(model.snapshot().lines.contains { $0.contains("fourth") })
    #expect(String(decoding: replies, as: UTF8.self).contains("\u{1b}[3;7R"))
    model.resize(columns: 30, rows: 5)
    #expect(model.snapshot().lines.count == 5)
    #expect(model.terminal.cols == 30)
}

@Test func screenDiffSkipsUnchangedFramesAndKeepsCursorInsideRightPane() {
    let model = SessionListModel(dataSource: EmptyTerminalDataSource())
    var renderer = EmbeddedScreenRenderer()
    let gridModel = TerminalGridModel(columns: layout.terminalColumns, rows: layout.terminalRows)
    gridModel.feed(Array("hello".utf8))
    let grid = gridModel.snapshot()
    let first = renderer.render(model: model, layout: layout, grid: grid, focused: true, terminalMessage: nil)
    #expect(first.contains("\u{1b}[4;\(layout.terminalColumn + 5)H"))
    #expect(!first.contains("\n"))
    #expect(renderer.render(model: model, layout: layout, grid: grid, focused: true, terminalMessage: nil).isEmpty)
    gridModel.feed(Array("\rhello".utf8))
    #expect(renderer.render(model: model, layout: layout, grid: gridModel.snapshot(), focused: true, terminalMessage: nil).isEmpty)
    gridModel.feed(Array("!".utf8))
    let next = renderer.render(model: model, layout: layout, grid: gridModel.snapshot(), focused: true, terminalMessage: nil)
    #expect(next.contains("hello!"))
    #expect(!next.contains("Banyan TUI"))
    #expect(!next.contains("[2J"))
}

@Test func embeddedDetachResizeAndReconnectDiscardStaleCallbacks() {
    let terminal = EmbeddedTerminal(changed: {})
    let first = RecordingTerminalTransport(), second = RecordingTerminalTransport()
    var staleOutput: (([UInt8]) -> Void)?, staleExit: ((Int32) -> Void)?
    terminal.connect(sessionName: "first", columns: 30, rows: 10) { _, _, receive, ended in
        staleOutput = receive; staleExit = ended
        receive(Array("first".utf8))
        return first
    }
    terminal.send([3, 27, 91, 65])
    terminal.resize(columns: 40, rows: 12)
    terminal.resize(columns: 40, rows: 12)
    #expect(first.inputs == [[3, 27, 91, 65]])
    #expect(first.sizes.map { $0.0 } == [40])
    terminal.connect(sessionName: "second", columns: 40, rows: 12) { _, _, receive, _ in
        staleOutput?(Array("stale".utf8)); staleExit?(1)
        receive(Array("second".utf8))
        return second
    }
    #expect(first.stopped)
    #expect(terminal.snapshot().grid?.lines[0].contains("second") == true)
    #expect(terminal.snapshot().grid?.lines[0].contains("stale") == false)
    #expect(terminal.snapshot().message == nil)
    terminal.stop()
    #expect(second.stopped)
    #expect(terminal.snapshot().grid == nil)
}

private final class RecordingTerminalTransport: TerminalTransport {
    var inputs: [[UInt8]] = [], sizes: [(Int, Int)] = [], stopped = false
    func send(_ bytes: [UInt8]) { inputs.append(bytes) }
    func resize(columns: Int, rows: Int) throws { sizes.append((columns, rows)) }
    func stop() { stopped = true }
}

private struct EmptyTerminalDataSource: SessionListDataSource {
    func loadActiveSessions() -> [SessionSnapshot] { [] }
    func loadHistory(limit: Int) -> [ImportedAgentSession] { [] }
}
