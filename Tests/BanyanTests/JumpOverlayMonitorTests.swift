@testable import Banyan
import AppKit
import Testing

@Test func jumpIndexMapsDigitsToOneBasedPositions() {
    #expect(JumpOverlayMonitor.jumpIndex(for: "1") == 1)
    #expect(JumpOverlayMonitor.jumpIndex(for: "9") == 9)
    #expect(JumpOverlayMonitor.jumpIndex(for: "0") == 10)
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

@Test func jumpIndexRejectsInvalidCharacters() {
    #expect(JumpOverlayMonitor.jumpIndex(for: " ") == nil)
    #expect(JumpOverlayMonitor.jumpIndex(for: "!") == nil)
    #expect(JumpOverlayMonitor.jumpIndex(for: "A") == nil)
}

@Test func jumpLabelMapsPositionsToDisplayKeys() {
    #expect(JumpOverlayMonitor.jumpLabel(for: 1) == "1")
    #expect(JumpOverlayMonitor.jumpLabel(for: 9) == "9")
    #expect(JumpOverlayMonitor.jumpLabel(for: 10) == "0")
    #expect(JumpOverlayMonitor.jumpLabel(for: 11) == "A")
    #expect(JumpOverlayMonitor.jumpLabel(for: 20) == "J")
    #expect(JumpOverlayMonitor.jumpLabel(for: 21) == "K")
    #expect(JumpOverlayMonitor.jumpLabel(for: 22) == "M")
    #expect(JumpOverlayMonitor.jumpLabel(for: 33) == "Z")
}

@Test func jumpLabelReturnsNilForOutOfRange() {
    #expect(JumpOverlayMonitor.jumpLabel(for: 0) == nil)
    #expect(JumpOverlayMonitor.jumpLabel(for: 34) == nil)
}

@Test func jumpIndexAndLabelAreInverses() {
    for index in 1...33 {
        guard let label = JumpOverlayMonitor.jumpLabel(for: index) else {
            Issue.record("No label for index \(index)")
            continue
        }
        let char = Character(label.lowercased())
        #expect(JumpOverlayMonitor.jumpIndex(for: char) == index)
    }
}

@Test func visibleJumpShortcutsActivateWithoutOverlayState() {
    #expect(JumpOverlayMonitor.shortcutIndex(for: "3", modifiers: .command) == 3)
    #expect(JumpOverlayMonitor.shortcutIndex(for: "0", modifiers: .command) == 10)
    #expect(JumpOverlayMonitor.shortcutIndex(for: "A", modifiers: [.command, .shift]) == 11)
    #expect(JumpOverlayMonitor.shortcutIndex(for: "3", modifiers: []) == nil)
    #expect(JumpOverlayMonitor.shortcutIndex(for: "A", modifiers: .command) == nil)
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
