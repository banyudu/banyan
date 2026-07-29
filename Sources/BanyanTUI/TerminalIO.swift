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
}

final class TerminalMode: TUIInput {
    private var original: termios?

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
        print(prompt, terminator: "")
        fflush(stdout)
        let line = Swift.readLine()
        enterRaw()
        return line
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
        print("\u{1b}[0m\u{1b}[2J\u{1b}[H", terminator: "")
    }
}
