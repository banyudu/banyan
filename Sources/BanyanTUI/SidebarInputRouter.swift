import BanyanCore

enum SidebarInputEvent: Equatable {
    case action(SessionListAction)
    case fallback
}

struct SidebarInputRouter {
    private var sequence: [UInt8] = []
    private var paste = false
    var hasPendingEscape: Bool { !sequence.isEmpty }

    mutating func consume(_ byte: UInt8) -> SidebarInputEvent? {
        if byte == 27 || !sequence.isEmpty {
            sequence.append(byte)
            if sequence.count == 1 || (sequence.count == 2 && byte == 91) { return nil }
            if sequence.count >= 3 && sequence.count <= 128 && !(64...126).contains(byte) { return nil }
            let completed = sequence
            sequence.removeAll()
            if completed == [27, 91, 50, 48, 48, 126] { paste = true; return nil }
            if completed == [27, 91, 50, 48, 49, 126] { paste = false; return nil }
            return paste ? nil : .action(SessionListAction(sequence: completed))
        }
        guard !paste else { return nil }
        return byte == 102 ? .fallback : .action(SessionListAction(byte: byte))
    }

    mutating func flushEscape() { sequence.removeAll() }
}
