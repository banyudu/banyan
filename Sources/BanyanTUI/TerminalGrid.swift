import Foundation
import SwiftTerm

struct TerminalGrid: Equatable {
    var lines: [String]
    var cursorColumn: Int
    var cursorRow: Int
    var cursorVisible: Bool
    var cursorStyle: Int
    var mouseEnabled: Bool
    var bracketedPaste: Bool
}

/// The portable SwiftTerm model never writes escape sequences to the host.
/// Only cell text and explicitly supported attributes pass through this adapter.
final class TerminalGridModel: TerminalDelegate {
    private(set) var terminal: Terminal!
    private var cursorVisible = true
    private var cursorStyle = 1
    var reply: ([UInt8]) -> Void = { _ in }

    init(columns: Int, rows: Int) {
        terminal = Terminal(delegate: self, options: TerminalOptions(
            cols: columns, rows: rows, scrollback: 5000, enableSixelReported: false,
            kittyImageCacheLimitBytes: 0, ansi256PaletteStrategy: .xterm))
    }

    func feed(_ bytes: [UInt8]) { terminal.feed(byteArray: bytes) }
    func resize(columns: Int, rows: Int) { terminal.resize(cols: columns, rows: rows) }

    func snapshot() -> TerminalGrid {
        var lines: [String] = []
        for row in 0..<terminal.rows {
            var line = "\u{1b}[0m"
            var attribute: Attribute?
            for column in 0..<terminal.cols {
                guard let cell = terminal.getCharData(col: column, row: row) else { continue }
                if column > 0, terminal.getCharData(col: column - 1, row: row)?.width == 2 { continue }
                if cell.attribute != attribute {
                    attribute = cell.attribute
                    line += Self.sgr(cell.attribute)
                }
                let text = Self.safe(String(terminal.getCharacter(for: cell)))
                line += text.isEmpty ? " " : text
            }
            lines.append(line + "\u{1b}[0m")
        }
        let cursor = terminal.getCursorLocation()
        return TerminalGrid(lines: lines, cursorColumn: min(terminal.cols - 1, cursor.x),
                            cursorRow: cursor.y, cursorVisible: cursorVisible,
                            cursorStyle: cursorStyle, mouseEnabled: terminal.mouseMode != .off,
                            bracketedPaste: terminal.bracketedPasteMode)
    }

    static func safe(_ text: String) -> String {
        String(text.unicodeScalars.filter { $0.value >= 32 && !(127...159).contains($0.value) })
    }

    static func padded(_ text: String, width: Int) -> String {
        var result = "", used = 0
        for character in safe(text) {
            let size = character.unicodeScalars.map { max(0, UnicodeUtil.columnWidth(rune: $0)) }.max() ?? 0
            guard used + size <= width else { break }
            result.append(character); used += size
        }
        return result + String(repeating: " ", count: max(0, width - used))
    }

    private static func sgr(_ attribute: Attribute) -> String {
        var values = ["0"]
        for (style, code): (CharacterStyle, String) in [(.bold, "1"), (.dim, "2"), (.italic, "3"),
                (.underline, "4"), (.blink, "5"), (.inverse, "7"), (.invisible, "8"), (.crossedOut, "9")] {
            if attribute.style.contains(style) { values.append(code) }
        }
        for (color, base) in [(attribute.fg, 38), (attribute.bg, 48)] {
            switch color {
            case .ansi256(let code): values.append("\(base);5;\(code)")
            case .trueColor(let r, let g, let b): values.append("\(base);2;\(r);\(g);\(b)")
            default: break
            }
        }
        return "\u{1b}[\(values.joined(separator: ";"))m"
    }

    func send(source: Terminal, data: ArraySlice<UInt8>) { reply(Array(data)) }
    func showCursor(source: Terminal) { cursorVisible = true }
    func hideCursor(source: Terminal) { cursorVisible = false }
    func cursorStyleChanged(source: Terminal, newStyle: CursorStyle) {
        switch newStyle {
        case .blinkBlock: cursorStyle = 1
        case .steadyBlock: cursorStyle = 2
        case .blinkUnderline: cursorStyle = 3
        case .steadyUnderline: cursorStyle = 4
        case .blinkBar: cursorStyle = 5
        case .steadyBar: cursorStyle = 6
        }
    }
}
