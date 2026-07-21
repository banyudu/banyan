import AppKit

/// Handles the always-visible session jump shortcuts and ⌘J/⌘K navigation.
/// Digits use ⌘+1…9; letters use ⌘⇧+A…Z so ordinary editing shortcuts remain free.
final class JumpOverlayMonitor {
    static let shared = JumpOverlayMonitor()

    var onJump: ((Int) -> Bool)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?

    private var keyMonitor: Any?

    private init() {}

    deinit {
        stop()
    }

    func start() {
        guard keyMonitor == nil else { return }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }

            if self.handleCmdJK(event) { return nil }
            if self.handleJumpKey(event) { return nil }
            return event
        }
    }

    func stop() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    // MARK: - Event handling

    private static let interestingModifiers: NSEvent.ModifierFlags = [.command, .shift, .control, .option]

    private func handleCmdJK(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers == .command else { return false }
        guard let chars = event.charactersIgnoringModifiers?.lowercased() else { return false }

        switch chars {
        case "j":
            onNext?()
            return true
        case "k":
            onPrevious?()
            return true
        default:
            return false
        }
    }

    private func handleJumpKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(Self.interestingModifiers)
        guard let char = event.charactersIgnoringModifiers?.lowercased().first else { return false }
        guard let index = Self.shortcutIndex(for: char, modifiers: modifiers) else { return false }
        return onJump?(index) ?? false
    }

    // MARK: - Key ↔ index mapping

    /// Maps a key character to a 1-based session index.
    /// "1"–"9" → 1–9, "a"–"z" → 10–35.
    static func jumpIndex(for char: Character) -> Int? {
        if let digit = char.wholeNumberValue, digit >= 1, digit <= 9 {
            return digit
        }
        guard let ascii = char.asciiValue else { return nil }
        let a = Character("a").asciiValue!
        let z = Character("z").asciiValue!
        guard ascii >= a, ascii <= z else { return nil }
        return 10 + Int(ascii - a)
    }

    static func shortcutIndex(for char: Character, modifiers: NSEvent.ModifierFlags) -> Int? {
        let modifiers = modifiers.intersection(interestingModifiers)
        if char.isNumber {
            guard modifiers == .command else { return nil }
        } else {
            guard modifiers == [.command, .shift] else { return nil }
        }
        return jumpIndex(for: Character(char.lowercased()))
    }

    /// Maps a 1-based session index to its jump key label.
    /// 1–9 → "1"–"9", 10–35 → "A"–"Z" (uppercase hints at ⌘⇧).
    static func jumpLabel(for oneBasedIndex: Int) -> String? {
        if oneBasedIndex >= 1, oneBasedIndex <= 9 {
            return String(oneBasedIndex)
        }
        if oneBasedIndex >= 10, oneBasedIndex <= 35 {
            let offset = oneBasedIndex - 10
            return String(UnicodeScalar(UInt8(Character("A").asciiValue!) + UInt8(offset)))
        }
        return nil
    }
}
