import BanyanCore
import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

protocol TUIInput {
    func readByte() -> UInt8?
    func readAction() -> SessionListAction?
    func readLine(prompt: String) -> String?
    func enterRaw()
    func restore()
    func readEvent(events: TUIEvents) -> TUIEvent?
    var layout: TerminalLayout { get }
}

extension TUIInput {
    func readEvent(events: TUIEvents) -> TUIEvent? { readAction().map(TUIEvent.action) }
    var layout: TerminalLayout { TerminalLayout(columns: 80, rows: 24) }
}

final class TerminalMode: TUIInput {
    private var original: termios?

    var layout: TerminalLayout {
        var size = winsize()
        guard ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &size) == 0, size.ws_col > 0, size.ws_row > 0 else {
            return TerminalLayout(columns: 80, rows: 24)
        }
        return TerminalLayout(columns: Int(size.ws_col), rows: Int(size.ws_row))
    }

    func readEvent(events: TUIEvents) -> TUIEvent? {
        while true {
            if let event = events.take() { return event }
            var descriptors = [pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0),
                               pollfd(fd: events.descriptor, events: Int16(POLLIN), revents: 0)]
            let result = poll(&descriptors, 2, -1)
            if result < 0 && errno == EINTR { continue }
            guard result > 0 else { return nil }
            if descriptors[1].revents != 0 { continue }
            if descriptors[0].revents != 0 {
                var bytes = [UInt8](repeating: 0, count: 16384)
                let count = read(STDIN_FILENO, &bytes, bytes.count)
                if count < 0 && errno == EINTR { continue }
                return count > 0 ? .input(Array(bytes.prefix(count))) : nil
            }
        }
    }

    init() {
        var attributes = termios()
        guard tcgetattr(STDIN_FILENO, &attributes) == 0 else { return }
        original = attributes
        enterRaw()
    }

    func readByte() -> UInt8? {
        var byte: UInt8 = 0
        guard read(STDIN_FILENO, &byte, 1) == 1 else { return nil }
        return byte
    }

    func readAction() -> SessionListAction? {
        guard let first = readByte() else { return nil }
        guard first == 27 else { return SessionListAction(byte: first) }

        // Escape sequences are short and arrive as a burst from a terminal.
        // Read the remainder only when available so a standalone Escape key
        // does not leave the TUI blocked waiting for more input.
        var sequence = [first]
        for _ in 0..<3 {
            guard let byte = readAvailableByte(timeoutMilliseconds: 50) else { break }
            sequence.append(byte)
            if byte == 126 || (sequence.count == 3 && [65, 66, 67, 68].contains(byte)) { break }
        }
        return SessionListAction(sequence: sequence)
    }

    func readLine(prompt: String) -> String? {
        restore()
        print("\u{1b}[?7h\u{1b}[?25h\u{1b}[?1000l\u{1b}[?1002l\u{1b}[?1006l\u{1b}[?2004l\r\n" + prompt, terminator: "")
        fflush(stdout)
        let line = Swift.readLine()
        enterRaw()
        print("\u{1b}[?7l", terminator: "")
        return line
    }

    func enterRaw() {
        guard let original else { return }
        var raw = original
        cfmakeraw(&raw)
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
    }

    func restore() {
        guard let original else { return }
        var attributes = original
        tcsetattr(STDIN_FILENO, TCSANOW, &attributes)
    }

    private func readAvailableByte(timeoutMilliseconds: Int32) -> UInt8? {
        var descriptor = pollfd(
            fd: Int32(STDIN_FILENO),
            events: Int16(POLLIN),
            revents: 0
        )
        guard poll(&descriptor, 1, timeoutMilliseconds) > 0 else { return nil }
        return readByte()
    }

    deinit {
        restore()
        print("\u{1b}[0m", terminator: "")
    }
}
