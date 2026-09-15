import AppKit
import BanyanCore
import SwiftUI

/// One definition of a keyboard chord, shared by the `NSEvent` monitor that
/// consumes it, the menu item that binds it, and the command palette row that
/// advertises it.
///
/// The app has no central shortcut registry — the jump tables, the menu
/// literals, and the palette labels are three separate sources of truth — so
/// chords added from here on carry their own. The displayed label is derived
/// from the bound modifiers instead of being retyped, which is what keeps the
/// advertised chord and the bound chord from drifting apart.
struct SessionShortcut {
    let key: Character
    let modifiers: NSEvent.ModifierFlags

    /// Modifiers worth comparing; everything else (caps lock, fn, numeric pad)
    /// is noise for shortcut matching.
    static let comparedModifiers: NSEvent.ModifierFlags = [.command, .shift, .control, .option]

    /// Menu and palette label, e.g. `⌘⌥J`. Command comes first to match the
    /// labels the sidebar and palette already show.
    var display: String {
        var label = ""
        if modifiers.contains(.control) { label += "⌃" }
        if modifiers.contains(.command) { label += "⌘" }
        if modifiers.contains(.option) { label += "⌥" }
        if modifiers.contains(.shift) { label += "⇧" }
        return label + key.uppercased()
    }

    var keyEquivalent: KeyEquivalent {
        KeyEquivalent(key)
    }

    var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if modifiers.contains(.command) { result.insert(.command) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        if modifiers.contains(.control) { result.insert(.control) }
        return result
    }

    func matches(character: Character, modifiers: NSEvent.ModifierFlags) -> Bool {
        character.lowercased() == key.lowercased()
            && modifiers.intersection(Self.comparedModifiers) == self.modifiers
    }
}

/// Moves selection to the nearest session that is waiting on a decision.
///
/// `⌥` reads as "same direction as ⌘J/⌘K, narrower set". The obvious `⌘⇧J` /
/// `⌘⇧K` mirror is unavailable: `⌘⇧`+letter is the session slot-jump range, and
/// those chords are reserved even when their slot is empty.
enum SessionAttentionShortcuts {
    static let next = SessionShortcut(key: "j", modifiers: [.command, .option])
    static let previous = SessionShortcut(key: "k", modifiers: [.command, .option])

    static func direction(
        for character: Character,
        modifiers: NSEvent.ModifierFlags
    ) -> SessionSelectionDirection? {
        if next.matches(character: character, modifiers: modifiers) { return .next }
        if previous.matches(character: character, modifiers: modifiers) { return .previous }
        return nil
    }
}
