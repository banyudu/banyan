import BanyanCore
import Foundation

struct TerminalLayout: Equatable {
    let columns: Int
    let rows: Int
    var sidebarColumns: Int { columns < 40 ? 0 : min(34, columns / 3) }
    var terminalColumn: Int { sidebarColumns == 0 ? 1 : sidebarColumns + 2 }
    var terminalRow: Int { 4 }
    var terminalColumns: Int { max(1, columns - terminalColumn + 1) }
    var terminalRows: Int { max(1, rows - 4) }
}

/// Retains the host frame and rewrites only changed rows. It never emits a
/// newline, so drawing at the bottom/right edge cannot scroll away the sidebar.
struct EmbeddedScreenRenderer {
    private var previous: [String] = []
    private var previousCursor = ""
    private var previousLayout: TerminalLayout?

    mutating func invalidate() { previous = []; previousCursor = ""; previousLayout = nil }

    mutating func render(model: SessionListModel, layout: TerminalLayout, grid: TerminalGrid?,
                         focused: Bool, terminalMessage: String?) -> String {
        let pad = TerminalGridModel.padded
        var lines = [String](repeating: "", count: layout.rows)
        guard layout.rows >= 5 else {
            lines[0] = pad("Enlarge terminal to use Banyan", layout.columns)
            return diff(lines: lines, cursor: "\u{1b}[?25l", layout: layout)
        }
        lines[0] = pad("Banyan TUI | \(focused ? "terminal" : model.showingHistory ? "history" : "sessions") | Enter focus | Ctrl-] ] sidebar | Ctrl-] j/k switch", layout.columns)
        lines[1] = pad(terminalMessage ?? model.notice ?? "j/k navigate  h history  n shell  N custom  e rename  R recover  c close  x remove  r refresh  f full-screen attach  q quit", layout.columns)
        lines[2] = String(repeating: "─", count: layout.columns)
        let count = model.visibleRowCount
        let start = max(0, model.selectedIndex - layout.terminalRows + 1)
        let details: [String]
        if model.showingHistory, let item = model.selectedHistory {
            details = [item.title, item.provider.displayName, "cwd: \(item.cwd)", "Enter resume / T trim", item.transcriptURL.path]
        } else if let session = model.selectedPuckSession {
            details = ["\(session.provider)/\(session.model)", "id: \(session.id)", "workspace: \(session.workspace)", "Enter to open Puck"]
        } else {
            details = [terminalMessage ?? "Select a session; Enter focuses the terminal"]
        }
        for row in 0..<layout.terminalRows {
            let index = start + row
            var left = ""
            if index < count {
                let title: String
                if model.showingHistory { title = model.history[index].title }
                else if index < model.sessions.count { title = model.sessions[index].title }
                else { title = model.puckSessions[index - model.sessions.count].provider }
                left = "\(index == model.selectedIndex ? ">" : " ") \(title)"
            }
            let right = grid?.lines.indices.contains(row) == true ? grid!.lines[row]
                : pad(row < details.count ? details[row] : "", layout.terminalColumns)
            lines[row + 3] = layout.sidebarColumns == 0 ? right
                : pad(left, layout.sidebarColumns) + "│" + right
        }
        lines[layout.rows - 1] = pad(focused
            ? "Ctrl-] ] sidebar | Ctrl-] j/k switch | Ctrl-] Ctrl-] sends prefix | tmux prefix + [ scrollback"
            : "Enter terminal | f fallback attach | p Puck | / history search | q quit", layout.columns)
        let mouse = focused && grid?.mouseEnabled == true
        // Ask for SGR mouse only: coordinates can then be translated to the pane.
        let modes = "\u{1b}[?1000\(mouse ? "h" : "l")\u{1b}[?1002\(mouse ? "h" : "l")\u{1b}[?1006\(mouse ? "h" : "l")\u{1b}[?2004h"
        var cursor = modes + "\u{1b}[?25l"
        if focused, let grid, grid.cursorVisible,
           (0..<layout.terminalRows).contains(grid.cursorRow), (0..<layout.terminalColumns).contains(grid.cursorColumn) {
            cursor = modes + "\u{1b}[\(layout.terminalRow + grid.cursorRow);\(layout.terminalColumn + grid.cursorColumn)H\u{1b}[\(grid.cursorStyle) q\u{1b}[?25h"
        }
        return diff(lines: lines, cursor: cursor, layout: layout)
    }

    private mutating func diff(lines: [String], cursor: String, layout: TerminalLayout) -> String {
        var output = previousLayout == layout ? "" : "\u{1b}[0m\u{1b}[2J"
        for (row, line) in lines.enumerated() where previousLayout != layout || !previous.indices.contains(row) || previous[row] != line {
            output += "\u{1b}[?25l\u{1b}[\(row + 1);1H\u{1b}[0m" + line + "\u{1b}[0m"
        }
        if !output.isEmpty || cursor != previousCursor { output += cursor }
        previous = lines; previousCursor = cursor; previousLayout = layout
        return output
    }
}
