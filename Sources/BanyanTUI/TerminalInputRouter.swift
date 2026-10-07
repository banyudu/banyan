import Foundation

enum TerminalInputEvent: Equatable {
    case bytes([UInt8])
    case sidebar
    case next
    case previous
}

/// Ctrl-] is Banyan's prefix; tmux's own prefix remains available. Bracketed
/// pastes are opaque so pasted commands cannot accidentally navigate the UI.
struct TerminalInputRouter {
    private var prefix = false
    private var escape: [UInt8] = []
    private var paste = false

    mutating func consume(_ bytes: [UInt8], layout: TerminalLayout, mouseEnabled: Bool,
                          bracketedPaste: Bool = true) -> [TerminalInputEvent] {
        var events: [TerminalInputEvent] = [], output: [UInt8] = []
        func flush() {
            if !output.isEmpty { events.append(.bytes(output)); output.removeAll() }
        }
        for byte in bytes {
            if !escape.isEmpty {
                escape.append(byte)
                if escape.count == 2 && byte != 91 {
                    output += escape; escape.removeAll(); continue
                }
                if escape.count >= 3 && (64...126).contains(byte) {
                    if escape == [27, 91, 50, 48, 48, 126] { paste = true }
                    if escape == [27, 91, 50, 48, 49, 126] { paste = false }
                    if !bracketedPaste && (escape == [27, 91, 50, 48, 48, 126] || escape == [27, 91, 50, 48, 49, 126]) {
                        // Host paste mode is always on, but the child may not request it.
                    } else if !paste, escape.starts(with: [27, 91, 60]) {
                        if mouseEnabled { output += Self.translateMouse(escape, layout: layout) }
                    } else { output += escape }
                    escape.removeAll()
                } else if escape.count > 128 {
                    output += escape; escape.removeAll()
                }
                continue
            }
            if byte == 27 { escape = [byte]; continue }
            if !paste && prefix {
                prefix = false
                switch byte {
                case 93: flush(); events.append(.sidebar)
                case 106: flush(); events.append(.next)
                case 107: flush(); events.append(.previous)
                case 29: output.append(29)
                default: output += [29, byte]
                }
            } else if !paste && byte == 29 {
                prefix = true
            } else { output.append(byte) }
        }
        flush()
        return events
    }

    // A lone Escape is released by an event-triggered short deadline, never by
    // periodic polling. Longer CSI sequences may span any number of reads.
    mutating func flushEscape() -> [UInt8] {
        defer { escape.removeAll() }
        return escape
    }

    var hasPendingEscape: Bool { !escape.isEmpty }

    private static func translateMouse(_ bytes: [UInt8], layout: TerminalLayout) -> [UInt8] {
        let value = String(decoding: bytes.dropFirst(3).dropLast(), as: UTF8.self)
        let fields = value.split(separator: ";").compactMap { Int($0) }
        guard fields.count == 3 else { return [] }
        let x = fields[1] - layout.terminalColumn + 1
        let y = fields[2] - layout.terminalRow + 1
        guard (1...layout.terminalColumns).contains(x), (1...layout.terminalRows).contains(y) else { return [] }
        return Array("\u{1b}[<\(fields[0]);\(x);\(y)\(Character(UnicodeScalar(bytes.last!)))".utf8)
    }
}
