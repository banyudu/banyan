import AppKit

/// Handles the always-visible session jump shortcuts and ⌘J/⌘K navigation.
/// Digits use ⌘+0…9; letters use ⌘⇧+A…Z so ordinary editing shortcuts remain free;
/// function keys use ⌘+F1…F12 (⌘⇧3/4/5 stay free for macOS screenshots).
/// L and S are reserved for switching between the Linear and Sessions sidebars;
/// N is reserved for Cmd+Shift+N, the plain-terminal fallback.
final class JumpOverlayMonitor {
    var onJump: ((Int) -> Bool)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onHandoff: (() -> Bool)?

    private var keyMonitor: Any?

    init() {}

    deinit {
        stop()
    }

    func start() {
        guard keyMonitor == nil else { return }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }

            if self.handleHandoff(event) { return nil }
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

    private func handleHandoff(_ event: NSEvent) -> Bool {
        guard let char = event.charactersIgnoringModifiers?.lowercased().first,
              Self.isHandoffShortcut(for: char, modifiers: event.modifierFlags) else {
            return false
        }
        return onHandoff?() ?? false
    }

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
        return Self.dispatchJumpShortcut(for: char, modifiers: modifiers, onJump: onJump)
    }

    // MARK: - Key ↔ index mapping

    private static let sessionJumpLetters = Array("abcdefghijkmopqrtuvwxyz")

    /// F-keys arrive in `charactersIgnoringModifiers` as private-use Unicode
    /// scalars (NSF1FunctionKey…NSF12FunctionKey) instead of printable characters.
    private static let sessionJumpFunctionKeys: [Character] =
        (UInt32(0xF704)...UInt32(0xF70F)).compactMap { UnicodeScalar($0).map(Character.init) }

    /// Maps a key character to a 1-based session index.
    /// "0" → 1, "1"–"9" → 2–10; letters other than L, N, and S → 11–33;
    /// F1–F12 → 34–45.
    static func jumpIndex(for char: Character) -> Int? {
        if let digit = char.wholeNumberValue, digit >= 0, digit <= 9 {
            return digit + 1
        }
        if let offset = sessionJumpFunctionKeys.firstIndex(of: char) {
            return 34 + offset
        }
        guard char == Character(char.lowercased()),
              let offset = sessionJumpLetters.firstIndex(of: char) else {
            return nil
        }
        return 11 + offset
    }

    static func shortcutIndex(for char: Character, modifiers: NSEvent.ModifierFlags) -> Int? {
        let modifiers = modifiers.intersection(interestingModifiers)
        if char.isNumber || sessionJumpFunctionKeys.contains(char) {
            guard modifiers == .command else { return nil }
        } else {
            guard modifiers == [.command, .shift] else { return nil }
        }
        return jumpIndex(for: Character(char.lowercased()))
    }

    /// Jump chords are reserved even when their numbered destination does not
    /// currently exist. Letting an unhandled chord propagate makes ⌘⇧A/C/F fall
    /// through to terminal select-all/copy/find behavior, which is surprising
    /// while the sidebar advertises those keys as session shortcuts.
    static func dispatchJumpShortcut(
        for char: Character,
        modifiers: NSEvent.ModifierFlags,
        onJump: ((Int) -> Bool)?
    ) -> Bool {
        guard let index = shortcutIndex(for: char, modifiers: modifiers) else {
            return false
        }
        _ = onJump?(index)
        return true
    }

    static func isHandoffShortcut(
        for char: Character,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        let normalizedModifiers = modifiers.intersection(interestingModifiers)
        return char.lowercased() == "h"
            && normalizedModifiers == [.command, .option, .shift]
    }

    /// Maps a 1-based session index to its jump key label.
    /// 1 → "0", 2–10 → "1"–"9", 11–33 → letters excluding L, N, and S,
    /// 34–45 → "F1"–"F12".
    static func jumpLabel(for oneBasedIndex: Int) -> String? {
        if oneBasedIndex >= 1, oneBasedIndex <= 10 {
            return String(oneBasedIndex - 1)
        }
        if oneBasedIndex >= 11 {
            let offset = oneBasedIndex - 11
            if sessionJumpLetters.indices.contains(offset) {
                return String(sessionJumpLetters[offset]).uppercased()
            }
            let functionOffset = offset - sessionJumpLetters.count
            guard sessionJumpFunctionKeys.indices.contains(functionOffset) else { return nil }
            return "F\(functionOffset + 1)"
        }
        return nil
    }

    /// Full chord for a session index as shown in menus and the command palette,
    /// e.g. 1 → "⌘0", 11 → "⌘⇧A", 34 → "⌘F1".
    static func shortcutDisplay(for oneBasedIndex: Int) -> String? {
        guard let label = jumpLabel(for: oneBasedIndex) else { return nil }
        if oneBasedIndex <= 10 || label.hasPrefix("F") {
            return "⌘\(label)"
        }
        return "⌘⇧\(label)"
    }
}
