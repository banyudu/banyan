import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

func readByte() -> UInt8? {
    var byte: UInt8 = 0
    guard read(STDIN_FILENO, &byte, 1) == 1 else { return nil }
    return byte
}

final class TerminalMode {
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
