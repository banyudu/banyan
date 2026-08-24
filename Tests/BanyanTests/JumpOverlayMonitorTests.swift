@testable import Banyan
import AppKit
import Testing

@Test func jumpIndexMapsDigitsToPositionsStartingAtZero() {
    #expect(JumpOverlayMonitor.jumpIndex(for: "0") == 1)
    #expect(JumpOverlayMonitor.jumpIndex(for: "1") == 2)
    #expect(JumpOverlayMonitor.jumpIndex(for: "9") == 10)
}

@Test func jumpIndexMapsAllLetters() {
    #expect(JumpOverlayMonitor.jumpIndex(for: "a") == 11)
    #expect(JumpOverlayMonitor.jumpIndex(for: "b") == 12)
    #expect(JumpOverlayMonitor.jumpIndex(for: "j") == 20)
    #expect(JumpOverlayMonitor.jumpIndex(for: "k") == 21)
    #expect(JumpOverlayMonitor.jumpIndex(for: "l") == nil)
    #expect(JumpOverlayMonitor.jumpIndex(for: "n") == nil)
    #expect(JumpOverlayMonitor.jumpIndex(for: "s") == nil)
    #expect(JumpOverlayMonitor.jumpIndex(for: "m") == 22)
    #expect(JumpOverlayMonitor.jumpIndex(for: "z") == 33)
}

@Test func jumpIndexMapsFunctionKeysAfterLetters() {
    #expect(JumpOverlayMonitor.jumpIndex(for: fKey(1)) == 34)
    #expect(JumpOverlayMonitor.jumpIndex(for: fKey(5)) == 38)
    #expect(JumpOverlayMonitor.jumpIndex(for: fKey(12)) == 45)
}

@Test func jumpIndexRejectsInvalidCharacters() {
    #expect(JumpOverlayMonitor.jumpIndex(for: " ") == nil)
    #expect(JumpOverlayMonitor.jumpIndex(for: "!") == nil)
    #expect(JumpOverlayMonitor.jumpIndex(for: "A") == nil)
}

@Test func jumpLabelMapsPositionsToDisplayKeysStartingAtZero() {
    #expect(JumpOverlayMonitor.jumpLabel(for: 1) == "0")
    #expect(JumpOverlayMonitor.jumpLabel(for: 9) == "8")
    #expect(JumpOverlayMonitor.jumpLabel(for: 10) == "9")
    #expect(JumpOverlayMonitor.jumpLabel(for: 11) == "A")
    #expect(JumpOverlayMonitor.jumpLabel(for: 20) == "J")
    #expect(JumpOverlayMonitor.jumpLabel(for: 21) == "K")
    #expect(JumpOverlayMonitor.jumpLabel(for: 22) == "M")
    #expect(JumpOverlayMonitor.jumpLabel(for: 33) == "Z")
    #expect(JumpOverlayMonitor.jumpLabel(for: 34) == "F1")
    #expect(JumpOverlayMonitor.jumpLabel(for: 45) == "F12")
}

@Test func jumpLabelReturnsNilForOutOfRange() {
    #expect(JumpOverlayMonitor.jumpLabel(for: 0) == nil)
    #expect(JumpOverlayMonitor.jumpLabel(for: 46) == nil)
}

@Test func jumpIndexAndLabelAreInverses() {
    for index in 1...45 {
        guard let label = JumpOverlayMonitor.jumpLabel(for: index) else {
            Issue.record("No label for index \(index)")
            continue
        }
        #expect(JumpOverlayMonitor.jumpIndex(for: jumpKeyCharacter(forLabel: label)) == index)
    }
}

@Test func shortcutDisplayMatchesActualChordModifiers() {
    #expect(JumpOverlayMonitor.shortcutDisplay(for: 1) == "⌘0")
    #expect(JumpOverlayMonitor.shortcutDisplay(for: 10) == "⌘9")
    #expect(JumpOverlayMonitor.shortcutDisplay(for: 11) == "⌘⇧A")
    #expect(JumpOverlayMonitor.shortcutDisplay(for: 33) == "⌘⇧Z")
    #expect(JumpOverlayMonitor.shortcutDisplay(for: 34) == "⌘F1")
    #expect(JumpOverlayMonitor.shortcutDisplay(for: 45) == "⌘F12")
    #expect(JumpOverlayMonitor.shortcutDisplay(for: 46) == nil)
}

@Test func visibleJumpShortcutsActivateWithoutOverlayState() {
    #expect(JumpOverlayMonitor.shortcutIndex(for: "3", modifiers: .command) == 4)
    #expect(JumpOverlayMonitor.shortcutIndex(for: "0", modifiers: .command) == 1)
    #expect(JumpOverlayMonitor.shortcutIndex(for: "A", modifiers: [.command, .shift]) == 11)
    #expect(JumpOverlayMonitor.shortcutIndex(for: "3", modifiers: []) == nil)
    #expect(JumpOverlayMonitor.shortcutIndex(for: "A", modifiers: .command) == nil)
}

@Test func functionKeyShortcutsRequirePlainCommand() {
    #expect(JumpOverlayMonitor.shortcutIndex(for: fKey(1), modifiers: .command) == 34)
    #expect(JumpOverlayMonitor.shortcutIndex(for: fKey(12), modifiers: .command) == 45)
    #expect(JumpOverlayMonitor.shortcutIndex(for: fKey(1), modifiers: [.command, .shift]) == nil)
    #expect(JumpOverlayMonitor.shortcutIndex(for: fKey(1), modifiers: []) == nil)
}

@Test func functionKeyShortcutIsConsumedWhenDestinationDoesNotExist() {
    var requestedIndex: Int?
    let consumed = JumpOverlayMonitor.dispatchJumpShortcut(
        for: fKey(12),
        modifiers: .command,
        onJump: { index in
            requestedIndex = index
            return false
        }
    )

    #expect(requestedIndex == 45)
    #expect(consumed)
    #expect(JumpOverlayMonitor.dispatchJumpShortcut(
        for: fKey(1),
        modifiers: .command,
        onJump: nil
    ))
}

@Test func jumpShortcutIsConsumedWhenDestinationDoesNotExist() {
    var requestedIndex: Int?
    let consumed = JumpOverlayMonitor.dispatchJumpShortcut(
        for: "C",
        modifiers: [.command, .shift],
        onJump: { index in
            requestedIndex = index
            return false
        }
    )

    #expect(requestedIndex == 13)
    #expect(consumed)
    #expect(!JumpOverlayMonitor.dispatchJumpShortcut(
        for: "C",
        modifiers: .command,
        onJump: nil
    ))
}

@Test func handoffShortcutRequiresCommandOptionShiftH() {
    #expect(JumpOverlayMonitor.isHandoffShortcut(for: "h", modifiers: [.command, .option, .shift]))
    #expect(JumpOverlayMonitor.isHandoffShortcut(for: "H", modifiers: [.command, .option, .shift]))
    #expect(!JumpOverlayMonitor.isHandoffShortcut(for: "h", modifiers: [.command, .option]))
    #expect(!JumpOverlayMonitor.isHandoffShortcut(for: "h", modifiers: [.command, .shift]))
    #expect(!JumpOverlayMonitor.isHandoffShortcut(for: "j", modifiers: [.command, .option, .shift]))
}

private func fKey(_ number: Int) -> Character {
    Character(UnicodeScalar(UInt32(0xF703 + number))!)
}

private func jumpKeyCharacter(forLabel label: String) -> Character {
    if label.hasPrefix("F"), let number = Int(label.dropFirst()) {
        return fKey(number)
    }
    return Character(label.lowercased())
}
