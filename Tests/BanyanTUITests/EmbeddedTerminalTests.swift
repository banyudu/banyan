import Foundation
import Testing
@testable import BanyanTUI

@Test func terminalGridParsesANSIColorsCursorMovementAndAlternateScreen() {
    var grid = TerminalGrid(columns: 8, rows: 3)
    grid.feed(Data("hello\u{1b}[31m red\u{1b}[0m\u{1b}[2;1Hok".utf8))

    #expect(grid.visibleLines()[0].contains("hello"))
    #expect(grid.visibleLines()[0].contains("31m"))
    #expect(grid.visibleLines()[1].contains("ok"))

    grid.feed(Data("\u{1b}[?1049halt\u{1b}[?1049l".utf8))
    #expect(grid.visibleLines()[0].contains("hello"))
    #expect(!grid.alternateScreen)
}

@Test func controlModeOutputDecodesTmuxEscapes() {
    let data = ProcessTmuxControlModeClient.decode("hello\\n\\033[31mred\\033[0m\\141")
    #expect(String(decoding: data, as: UTF8.self) == "hello\n\u{1b}[31mred\u{1b}[0m a".replacingOccurrences(of: " ", with: ""))
}
