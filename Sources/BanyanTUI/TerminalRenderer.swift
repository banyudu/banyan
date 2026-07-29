import BanyanCore

protocol TUIRenderer {
    func render(
        sessions: [SessionSnapshot],
        history: [ImportedAgentSession],
        showingHistory: Bool,
        selectedIndex: Int,
        notice: String?,
        tmux: any TmuxDisplayBackend
    ) -> String
}

struct StandardTUIRenderer: TUIRenderer {
    func render(
        sessions: [SessionSnapshot],
        history: [ImportedAgentSession],
        showingHistory: Bool,
        selectedIndex: Int,
        notice: String?,
        tmux: any TmuxDisplayBackend
    ) -> String {
        TerminalRenderer.render(
            sessions: sessions,
            history: history,
            showingHistory: showingHistory,
            selectedIndex: selectedIndex,
            notice: notice,
            tmux: tmux
        )
    }
}

struct TerminalRenderer {
    static func render(
        sessions: [SessionSnapshot],
        history: [ImportedAgentSession],
        showingHistory: Bool,
        selectedIndex: Int,
        notice: String?,
        tmux: any TmuxDisplayBackend
    ) -> String {
        var output = "\u{1b}[2J\u{1b}[H"
        let mode = showingHistory ? "history" : "active"
        let enterAction = showingHistory ? "resume/T trim" : "attach"
        output += "Banyan TUI  h \(mode)  j/k/arrows navigate  enter \(enterAction)  / search  e rename  n shell  N custom  R recover  c close  x remove  r refresh  q quit\n"
        if let notice { output += "\(notice)\n" }
        output += "\n"

        let sidebarWidth = 34
        let rightWidth = 45
        let rightLines = detailLines(
            sessions: sessions,
            history: history,
            showingHistory: showingHistory,
            selectedIndex: selectedIndex,
            tmux: tmux,
            width: rightWidth
        )
        output += (showingHistory ? "History" : "Sessions").padding(toLength: sidebarWidth, withPad: " ", startingAt: 0)
        output += "│ " + (showingHistory ? "History detail" : "Terminal detail") + "\n"
        output += String(repeating: "─", count: sidebarWidth) + "┼" + String(repeating: "─", count: rightWidth) + "\n"

        let rowCount = showingHistory ? history.count : sessions.count
        for row in 0..<max(max(rowCount, 1), rightLines.count) {
            var left = ""
            if showingHistory, row < history.count {
                let item = history[row]
                let marker = row == selectedIndex ? ">" : " "
                left = "\(marker) \(item.provider.badgeText) ◷ \(item.title)"
            } else if row < sessions.count {
                let session = sessions[row]
                let marker = row == selectedIndex ? ">" : " "
                left = "\(marker) \(session.status.emoji) \(session.title)"
            } else {
                left = row == 0
                    ? (showingHistory ? "(no history)" : "(no active sessions)")
                    : ""
            }
            output += left.padding(toLength: sidebarWidth, withPad: " ", startingAt: 0)
            output += "│ " + (row < rightLines.count ? rightLines[row] : "") + "\n"
        }
        return output
    }

    private static func detailLines(
        sessions: [SessionSnapshot],
        history: [ImportedAgentSession],
        showingHistory: Bool,
        selectedIndex: Int,
        tmux: any TmuxDisplayBackend,
        width: Int
    ) -> [String] {
        if showingHistory {
            guard history.indices.contains(selectedIndex) else { return [] }
            let item = history[selectedIndex]
            return [
                "\(item.provider.displayName) · \(item.title)",
                "cwd: \(item.cwd)",
                "updated: \(item.updatedAt.formatted(.iso8601))",
                "transcript: \(item.transcriptURL.path)"
            ].map { truncate($0, to: width) }
        }

        guard sessions.indices.contains(selectedIndex) else { return [] }
        let session = sessions[selectedIndex]
        var lines = [
            "\(session.status.emoji) \(session.status.label) · \(session.title)",
            "id: \(session.id)",
            "cwd: \(session.cwd)",
            "command: \(session.command.isEmpty ? "shell" : session.command)",
            "tmux: \(session.launchRequest.sessionName)"
        ]
        lines.append(contentsOf: terminalText(for: session, tmux: tmux))
        return lines.map { truncate($0, to: width) }
    }

    private static func terminalText(for session: SessionSnapshot, tmux: any TmuxDisplayBackend) -> [String] {
        let name = session.launchRequest.sessionName
        guard tmux.hasSession(named: name),
              let pane = tmux.primaryPaneSnapshot(named: name) else {
            return ["tmux session unavailable"]
        }
        let lines = tmux.captureCurrentVisibleText(paneID: pane.paneID)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        // tmux captures commonly end with a newline. Prefer the last actual
        // line so a trailing screen newline does not erase the preview.
        let text = lines.last(where: { !$0.isEmpty }) ?? lines.last ?? ""
        return ["last output: \(text)"]
    }

    private static func truncate(_ text: String, to width: Int) -> String {
        guard text.count > width else { return text }
        guard width > 1 else { return String(text.prefix(width)) }
        return String(text.prefix(width - 1)) + "…"
    }
}
