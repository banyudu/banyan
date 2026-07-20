import AppKit

/// Lightweight observable for the overlay's visibility, kept separate from
/// ``SessionStore`` so toggling it only re-renders the small badge views
/// rather than the entire sidebar List.
@MainActor
final class JumpOverlayState: ObservableObject {
    static let shared = JumpOverlayState()
    @Published var isVisible = false
    private init() {}
}

/// Handles the session jump overlay (hold ⌘ to show indices) and ⌘J/⌘K navigation.
///
/// When the user holds ⌘ alone for a short delay, session indices (1–9, A–Z) appear
/// in the sidebar. While visible, pressing a key jumps to that session. Quick
/// ⌘+key combos (copy, paste, etc.) are unaffected because the overlay does not
/// appear until the hold delay elapses.
final class JumpOverlayMonitor {
    static let shared = JumpOverlayMonitor()

    var onOverlayChanged: ((Bool) -> Void)?
    var onJump: ((Int) -> Bool)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?

    private var flagsMonitor: Any?
    private var keyMonitor: Any?
    private var overlayTimer: DispatchWorkItem?
    private(set) var isOverlayVisible = false

    private static let holdDelay: TimeInterval = 0.3

    private init() {}

    deinit {
        stop()
    }

    func start() {
        guard flagsMonitor == nil else { return }

        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }

            if self.overlayTimer != nil && !self.isOverlayVisible {
                self.overlayTimer?.cancel()
                self.overlayTimer = nil
            }

            if self.handleCmdJK(event) { return nil }
            if self.handleJumpKey(event) { return nil }
            return event
        }
    }

    func stop() {
        if let flagsMonitor {
            NSEvent.removeMonitor(flagsMonitor)
            self.flagsMonitor = nil
        }
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        overlayTimer?.cancel()
        overlayTimer = nil
        setOverlayVisible(false)
    }

    // MARK: - Event handling

    private static let interestingModifiers: NSEvent.ModifierFlags = [.command, .shift, .control, .option]

    private func handleFlagsChanged(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(Self.interestingModifiers)

        if modifiers == .command {
            guard overlayTimer == nil && !isOverlayVisible else { return }
            let timer = DispatchWorkItem { [weak self] in
                self?.setOverlayVisible(true)
            }
            overlayTimer = timer
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdDelay, execute: timer)
        } else if modifiers == [.command, .shift] {
            // Keep overlay visible when Shift is added to Cmd (needed for Cmd+Shift+letter jumps).
        } else {
            overlayTimer?.cancel()
            overlayTimer = nil
            setOverlayVisible(false)
        }
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
        guard isOverlayVisible else { return false }
        let modifiers = event.modifierFlags.intersection(Self.interestingModifiers)
        guard let char = event.charactersIgnoringModifiers?.lowercased().first else { return false }

        if char.isNumber {
            guard modifiers == .command else { return false }
        } else {
            guard modifiers == [.command, .shift] else { return false }
        }

        guard let index = Self.jumpIndex(for: char) else { return false }
        return onJump?(index) ?? false
    }

    private func setOverlayVisible(_ visible: Bool) {
        guard isOverlayVisible != visible else { return }
        isOverlayVisible = visible
        onOverlayChanged?(visible)
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
