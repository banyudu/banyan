import BanyanCore
import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

private struct BanyanTUI {
    private let database = SessionDatabase()
    private let tmux = TmuxBackend.shared
    private var sessions: [SessionSnapshot] = []
    private var selectedIndex = 0

    mutating func run() {
        let terminal = TerminalMode()
        while true {
            reload()
            render()

            guard let byte = readByte() else { break }
            switch byte {
            case 113: // q
                return
            case 106: // j
                selectedIndex = min(selectedIndex + 1, max(0, sessions.count - 1))
            case 107: // k
                selectedIndex = max(0, selectedIndex - 1)
            case 114: // r
                continue
            case 10, 13: // return
                terminal.restore()
                attachSelected()
                terminal.enterRaw()
            default:
                continue
            }
        }
    }

    private mutating func reload() {
        sessions = database.load().filter { $0.status != .closed }
        selectedIndex = min(selectedIndex, max(0, sessions.count - 1))
    }

    private func render() {
        let selected = sessions.indices.contains(selectedIndex) ? sessions[selectedIndex] : nil
        var output = "\u{1b}[2J\u{1b}[H"
        output += "Banyan TUI  j/k navigate  enter attach  r refresh  q quit\n\n"

        let sidebarWidth = 34
        output += "Sessions".padding(toLength: sidebarWidth, withPad: " ", startingAt: 0)
        output += "│ Terminal\n"
        output += String(repeating: "─", count: sidebarWidth) + "┼" + String(repeating: "─", count: 45) + "\n"

        let maxRows = max(sessions.count, 1)
        for row in 0..<maxRows {
            if row < sessions.count {
                let session = sessions[row]
                let marker = row == selectedIndex ? ">" : " "
                let label = "\(marker) \(session.status.emoji) \(session.title)"
                output += label.padding(toLength: sidebarWidth, withPad: " ", startingAt: 0)
                output += "│"
                if row == selectedIndex, let selected {
                    output += terminalText(for: selected)
                }
            } else {
                output += "(no active sessions)".padding(toLength: sidebarWidth, withPad: " ", startingAt: 0)
                output += "│"
            }
            output += "\n"
        }

        print(output, terminator: "")
        fflush(stdout)
    }

    private func terminalText(for session: SessionSnapshot) -> String {
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

    private func attachSelected() {
        guard sessions.indices.contains(selectedIndex) else { return }
        let session = sessions[selectedIndex]
        let name = session.tmuxSessionName ?? TmuxBackend.sessionName(for: session.id)
        print("\u{1b}[2J\u{1b}[H", terminator: "")
        fflush(stdout)

        let process = Process()
        process.executableURL = tmux.executableURL
        process.arguments = tmux.attachArguments(for: name)
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            print("Unable to attach to \(name): \(error.localizedDescription)")
        }
    }
}

private func readByte() -> UInt8? {
    var byte: UInt8 = 0
    guard read(STDIN_FILENO, &byte, 1) == 1 else { return nil }
    return byte
}

private final class TerminalMode {
    private var original: termios?

    init() {
        var attributes = termios()
        guard tcgetattr(STDIN_FILENO, &attributes) == 0 else { return }
        original = attributes
        enterRaw()
    }

    func enterRaw() {
        guard let original else { return }
        var raw = original
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
        raw.c_cc.0 = 1
        raw.c_cc.1 = 0
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
    }

    func restore() {
        guard let original else { return }
        var attributes = original
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &attributes)
    }

    deinit {
        restore()
        print("\u{1b}[0m\u{1b}[2J\u{1b}[H", terminator: "")
    }
}

private var app = BanyanTUI()
app.run()
