import BanyanCore

struct TerminalRenderer {
    static func render(
        sessions: [SessionSnapshot],
        history: [ImportedAgentSession],
        showingHistory: Bool,
        selectedIndex: Int,
        notice: String?,
        tmux: any TmuxDisplayBackend
    ) -> String {
        let selected = sessions.indices.contains(selectedIndex) ? sessions[selectedIndex] : nil
        var output = "\u{1b}[2J\u{1b}[H"
        let mode = showingHistory ? "active" : "history"
        let enterAction = showingHistory ? "resume/T trim" : "attach"
        output += "Banyan TUI  h \(mode)  j/k navigate  enter \(enterAction)  R recover  n new  c close  x remove  r refresh  q quit\n"
        if let notice { output += "\(notice)\n" }
        output += "\n"

        let sidebarWidth = 34
        output += (showingHistory ? "History" : "Sessions").padding(toLength: sidebarWidth, withPad: " ", startingAt: 0)
        output += "│ Terminal\n"
        output += String(repeating: "─", count: sidebarWidth) + "┼" + String(repeating: "─", count: 45) + "\n"

        let rowCount = showingHistory ? history.count : sessions.count
        for row in 0..<max(rowCount, 1) {
            if showingHistory, row < history.count {
                let item = history[row]
                let marker = row == selectedIndex ? ">" : " "
                let label = "\(marker) ◷ \(item.title)"
                output += label.padding(toLength: sidebarWidth, withPad: " ", startingAt: 0)
                output += "│ Enter to resume"
            } else if row < sessions.count {
                let session = sessions[row]
                let marker = row == selectedIndex ? ">" : " "
                let label = "\(marker) \(session.status.emoji) \(session.title)"
                output += label.padding(toLength: sidebarWidth, withPad: " ", startingAt: 0)
                output += "│"
                if row == selectedIndex, let selected {
                    output += terminalText(for: selected, tmux: tmux)
                }
            } else {
                let emptyLabel = showingHistory ? "(no history)" : "(no active sessions)"
                output += emptyLabel.padding(toLength: sidebarWidth, withPad: " ", startingAt: 0)
                output += "│"
            }
            output += "\n"
        }
        return output
    }

    private static func terminalText(for session: SessionSnapshot, tmux: any TmuxDisplayBackend) -> String {
        let name = session.tmuxSessionName ?? TmuxBackend.sessionName(for: session.id)
        guard tmux.hasSession(named: name),
              let pane = tmux.primaryPaneSnapshot(named: name) else {
            return " tmux session unavailable"
        }
        let text = tmux.captureCurrentVisibleText(paneID: pane.paneID)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(1)
            .first
            .map(String.init) ?? ""
        return " \(text)"
    }
}
