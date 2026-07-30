import Foundation

/// A small, frontend-neutral terminal screen. It intentionally stores cells
/// rather than lines so alternate screens, cursor movement, and ANSI redraws
/// work for full-screen programs as well as shells.
struct TerminalGrid: Sendable {
    struct Cell: Sendable, Equatable {
        var character: Character = " "
        var style: String = ""
    }

    private(set) var columns: Int
    private(set) var rows: Int
    private(set) var cells: [[Cell]]
    private(set) var cursorColumn = 0
    private(set) var cursorRow = 0
    private(set) var cursorVisible = true
    private(set) var alternateScreen = false

    private var savedCursor = (0, 0)
    private var mainCells: [[Cell]]
    private var alternateCells: [[Cell]]
    private var parser = ParserState.ground
    private var parameter = ""
    private var style = ""

    init(columns: Int, rows: Int) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        let blank = Array(repeating: Cell(), count: max(1, columns))
        self.cells = Array(repeating: blank, count: max(1, rows))
        self.mainCells = self.cells
        self.alternateCells = self.cells
    }

    mutating func resize(columns: Int, rows: Int) {
        let newColumns = max(1, columns)
        let newRows = max(1, rows)
        self.columns = newColumns
        self.rows = newRows
        cells = resized(cells, columns: newColumns, rows: newRows)
        mainCells = resized(mainCells, columns: newColumns, rows: newRows)
        alternateCells = resized(alternateCells, columns: newColumns, rows: newRows)
        cursorColumn = min(cursorColumn, newColumns - 1)
        cursorRow = min(cursorRow, newRows - 1)
    }

    mutating func feed(_ data: Data) {
        for byte in data { consume(byte) }
    }

    func visibleLines() -> [String] {
        cells.map { row in
            var result = ""
            var activeStyle = ""
            for cell in row {
                if cell.style != activeStyle {
                    result += "\u{1b}[\(cell.style.isEmpty ? "0" : cell.style)m"
                    activeStyle = cell.style
                }
                result.append(cell.character)
            }
            if !activeStyle.isEmpty { result += "\u{1b}[0m" }
            return result
        }
    }

    private enum ParserState { case ground, escape, csi }

    private mutating func consume(_ byte: UInt8) {
        switch parser {
        case .ground:
            if byte == 0x1b { parser = .escape }
            else if byte == 0x0a { newline() }
            else if byte == 0x0d { cursorColumn = 0 }
            else if byte == 0x08 { cursorColumn = max(0, cursorColumn - 1) }
            else if byte >= 0x20 && byte != 0x7f { put(Character(UnicodeScalar(byte))) }
        case .escape:
            if byte == 0x5b { parser = .csi; parameter = "" }
            else if byte == 0x37 { savedCursor = (cursorColumn, cursorRow); parser = .ground }
            else if byte == 0x38 { (cursorColumn, cursorRow) = savedCursor; parser = .ground }
            else if byte == 0x63 { clear(); parser = .ground }
            else { parser = .ground }
        case .csi:
            if byte >= 0x30 && byte <= 0x3f { parameter.append(Character(UnicodeScalar(byte))) }
            else if byte >= 0x40 && byte <= 0x7e { applyCSI(final: byte); parser = .ground }
        }
    }

    private mutating func applyCSI(final: UInt8) {
        let privateMode = parameter.first == "?"
        let values = parameter.trimmingCharacters(in: CharacterSet(charactersIn: "?"))
            .split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        let first = max(1, values.first ?? 1)
        switch final {
        case 0x48, 0x66: cursorRow = min(rows - 1, max(0, (values.first ?? 1) - 1)); cursorColumn = min(columns - 1, max(0, (values.dropFirst().first ?? 1) - 1))
        case 0x41: cursorRow = max(0, cursorRow - first)
        case 0x42, 0x65: cursorRow = min(rows - 1, cursorRow + first)
        case 0x43, 0x61: cursorColumn = min(columns - 1, cursorColumn + first)
        case 0x44: cursorColumn = max(0, cursorColumn - first)
        case 0x47, 0x60: cursorColumn = min(columns - 1, max(0, first - 1))
        case 0x4a: eraseDisplay(mode: values.first ?? 0)
        case 0x4b: eraseLine(mode: values.first ?? 0)
        case 0x6d: style = parameter.isEmpty ? "" : parameter
        case 0x68 where privateMode && parameter.contains("25"): cursorVisible = true
        case 0x6c where privateMode && parameter.contains("25"): cursorVisible = false
        case 0x68 where privateMode && parameter.contains("1049"):
            mainCells = cells; cells = alternateCells; alternateScreen = true; cursorColumn = 0; cursorRow = 0
        case 0x6c where privateMode && parameter.contains("1049"):
            alternateCells = cells; cells = mainCells; alternateScreen = false; cursorColumn = 0; cursorRow = 0
        default: break
        }
    }

    private mutating func put(_ character: Character) {
        cells[cursorRow][cursorColumn] = Cell(character: character, style: style)
        cursorColumn += 1
        if cursorColumn >= columns { cursorColumn = 0; newline() }
    }

    private mutating func newline() {
        if cursorRow == rows - 1 { cells.removeFirst(); cells.append(Array(repeating: Cell(), count: columns)) }
        else { cursorRow += 1 }
    }

    private mutating func clear() { cells = Array(repeating: Array(repeating: Cell(), count: columns), count: rows); cursorColumn = 0; cursorRow = 0 }
    private mutating func eraseDisplay(mode: Int) { if mode == 2 || mode == 3 { clear() } else if mode == 0 { for row in cursorRow..<rows { for column in (row == cursorRow ? cursorColumn : 0)..<columns { cells[row][column] = Cell() } } } }
    private mutating func eraseLine(mode: Int) { let start = mode == 1 ? 0 : cursorColumn; let end = mode == 1 ? cursorColumn : columns; for column in start..<end { cells[cursorRow][column] = Cell() } }
    private func resized(_ value: [[Cell]], columns: Int, rows: Int) -> [[Cell]] { Array(value.prefix(rows)).map { Array($0.prefix(columns)) + Array(repeating: Cell(), count: max(0, columns - $0.count)) } + Array(repeating: Array(repeating: Cell(), count: columns), count: max(0, rows - value.count)) }
}

final class TerminalGridStore: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TerminalGrid
    init(columns: Int, rows: Int) { value = TerminalGrid(columns: columns, rows: rows) }
    func feed(_ data: Data) { lock.lock(); value.feed(data); lock.unlock() }
    func resize(columns: Int, rows: Int) { lock.lock(); value.resize(columns: columns, rows: rows); lock.unlock() }
    func snapshot() -> TerminalGrid { lock.lock(); defer { lock.unlock() }; return value }
}
