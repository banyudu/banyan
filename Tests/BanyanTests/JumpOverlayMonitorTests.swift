@testable import Banyan
import AppKit
import BanyanCore
import Testing

@Test func jumpIndexMapsDigitsToPositionsStartingAtZero() {
    #expect(JumpOverlayMonitor.jumpIndex(for: "0") == 1)
    #expect(JumpOverlayMonitor.jumpIndex(for: "1") == 2)
    #expect(JumpOverlayMonitor.jumpIndex(for: "9") == 10)
}

@Test func jumpIndexMapsAllLetters() {
    #expect(JumpOverlayMonitor.jumpIndex(for: "a") == 11)
    #expect(JumpOverlayMonitor.jumpIndex(for: "b") == 12)
    #expect(JumpOverlayMonitor.jumpIndex(for: "j") == nil)
    #expect(JumpOverlayMonitor.jumpIndex(for: "k") == nil)
    #expect(JumpOverlayMonitor.jumpIndex(for: "l") == nil)
    #expect(JumpOverlayMonitor.jumpIndex(for: "n") == nil)
    #expect(JumpOverlayMonitor.jumpIndex(for: "s") == nil)
    #expect(JumpOverlayMonitor.jumpIndex(for: "m") == 20)
    #expect(JumpOverlayMonitor.jumpIndex(for: "z") == 31)
}

@Test func jumpIndexMapsFunctionKeysAfterLetters() {
    #expect(JumpOverlayMonitor.jumpIndex(for: fKey(1)) == 32)
    #expect(JumpOverlayMonitor.jumpIndex(for: fKey(5)) == 36)
    #expect(JumpOverlayMonitor.jumpIndex(for: fKey(12)) == 43)
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
    #expect(JumpOverlayMonitor.jumpLabel(for: 20) == "M")
    #expect(JumpOverlayMonitor.jumpLabel(for: 21) == "O")
    #expect(JumpOverlayMonitor.jumpLabel(for: 31) == "Z")
    #expect(JumpOverlayMonitor.jumpLabel(for: 32) == "F1")
    #expect(JumpOverlayMonitor.jumpLabel(for: 43) == "F12")
}

@Test func jumpLabelReturnsNilForOutOfRange() {
    #expect(JumpOverlayMonitor.jumpLabel(for: 0) == nil)
    #expect(JumpOverlayMonitor.jumpLabel(for: 44) == nil)
}

@Test func jumpIndexAndLabelAreInverses() {
    for index in 1...JumpOverlayMonitor.maxSessionSlots {
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
    #expect(JumpOverlayMonitor.shortcutDisplay(for: 16) == "⌘⇧F")
    #expect(JumpOverlayMonitor.shortcutDisplay(for: 31) == "⌘⇧Z")
    #expect(JumpOverlayMonitor.shortcutDisplay(for: 32) == "⌘F1")
    #expect(JumpOverlayMonitor.shortcutDisplay(for: 43) == "⌘F12")
    #expect(JumpOverlayMonitor.shortcutDisplay(for: 44) == nil)
}

@Test func visibleJumpShortcutsActivateWithoutOverlayState() {
    #expect(JumpOverlayMonitor.shortcutIndex(for: "3", modifiers: .command) == 4)
    #expect(JumpOverlayMonitor.shortcutIndex(for: "0", modifiers: .command) == 1)
    #expect(JumpOverlayMonitor.shortcutIndex(for: "A", modifiers: [.command, .shift]) == 11)
    #expect(JumpOverlayMonitor.shortcutIndex(for: "3", modifiers: []) == nil)
    #expect(JumpOverlayMonitor.shortcutIndex(for: "A", modifiers: .command) == nil)
}

@Test func functionKeyShortcutsRequirePlainCommand() {
    #expect(JumpOverlayMonitor.shortcutIndex(for: fKey(1), modifiers: .command) == 32)
    #expect(JumpOverlayMonitor.shortcutIndex(for: fKey(12), modifiers: .command) == 43)
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

    #expect(requestedIndex == 43)
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

@Test func attentionShortcutsUseCommandOptionJAndK() {
    #expect(SessionAttentionShortcuts.next.display == "⌘⌥J")
    #expect(SessionAttentionShortcuts.previous.display == "⌘⌥K")
    #expect(SessionAttentionShortcuts.direction(for: "j", modifiers: [.command, .option]) == .next)
    #expect(SessionAttentionShortcuts.direction(for: "K", modifiers: [.command, .option]) == .previous)
}

@Test func attentionShortcutsIgnoreOtherModifierCombinations() {
    #expect(SessionAttentionShortcuts.direction(for: "j", modifiers: .command) == nil)
    #expect(SessionAttentionShortcuts.direction(for: "j", modifiers: .option) == nil)
    #expect(SessionAttentionShortcuts.direction(for: "j", modifiers: [.command, .option, .shift]) == nil)
    #expect(SessionAttentionShortcuts.direction(for: "h", modifiers: [.command, .option]) == nil)
}

@Test func attentionShortcutsDoNotCollideWithJumpOrHandoffChords() {
    // ⌘⇧J/⌘⇧K belong to project navigation, ⌘⌥⇧H to handoff; ⌘⌥J/⌘⌥K must
    // stay out of both so no chord is handled twice.
    #expect(JumpOverlayMonitor.shortcutIndex(for: "j", modifiers: [.command, .option]) == nil)
    #expect(JumpOverlayMonitor.shortcutIndex(for: "k", modifiers: [.command, .option]) == nil)
    #expect(!JumpOverlayMonitor.isHandoffShortcut(for: "j", modifiers: [.command, .option]))
    #expect(SessionAttentionShortcuts.direction(for: "j", modifiers: [.command, .shift]) == nil)
}

@Test func attentionShortcutDispatchForwardsDirection() {
    var directions: [SessionSelectionDirection] = []
    let consumedNext = JumpOverlayMonitor.dispatchAttentionShortcut(
        for: "j",
        modifiers: [.command, .option],
        onSelect: { directions.append($0) }
    )
    let consumedPrevious = JumpOverlayMonitor.dispatchAttentionShortcut(
        for: "k",
        modifiers: [.command, .option],
        onSelect: { directions.append($0) }
    )

    #expect(consumedNext)
    #expect(consumedPrevious)
    #expect(directions == [.next, .previous])
}

@Test func attentionShortcutIsConsumedEvenWithoutAHandler() {
    // Otherwise an unhandled ⌥J/⌥K types ∆/˚ into the focused terminal.
    #expect(JumpOverlayMonitor.dispatchAttentionShortcut(
        for: "j",
        modifiers: [.command, .option],
        onSelect: nil
    ))
    #expect(JumpOverlayMonitor.dispatchAttentionShortcut(
        for: "k",
        modifiers: [.command, .option],
        onSelect: nil
    ))
}

@Test func unrelatedChordsAreNotConsumedAsAttentionShortcuts() {
    #expect(!JumpOverlayMonitor.dispatchAttentionShortcut(
        for: "j",
        modifiers: .command,
        onSelect: nil
    ))
}

@Test func projectShortcutsUseCommandShiftJAndK() {
    #expect(SessionProjectShortcuts.next.display == "⌘⇧J")
    #expect(SessionProjectShortcuts.previous.display == "⌘⇧K")
    #expect(SessionProjectShortcuts.direction(for: "j", modifiers: [.command, .shift]) == .next)
    #expect(SessionProjectShortcuts.direction(for: "K", modifiers: [.command, .shift]) == .previous)
    #expect(SessionProjectShortcuts.direction(for: "j", modifiers: .command) == nil)
    #expect(SessionProjectShortcuts.direction(for: "j", modifiers: [.command, .option, .shift]) == nil)
}

@Test func projectShortcutDispatchForwardsDirectionAndIsConsumedWithoutAHandler() {
    var directions: [SessionSelectionDirection] = []
    #expect(JumpOverlayMonitor.dispatchProjectShortcut(
        for: "j",
        modifiers: [.command, .shift],
        onProject: { directions.append($0) }
    ))
    #expect(JumpOverlayMonitor.dispatchProjectShortcut(
        for: "k",
        modifiers: [.command, .shift],
        onProject: { directions.append($0) }
    ))
    #expect(directions == [.next, .previous])

    #expect(JumpOverlayMonitor.dispatchProjectShortcut(
        for: "j",
        modifiers: [.command, .shift],
        onProject: nil
    ))
    #expect(!JumpOverlayMonitor.dispatchProjectShortcut(
        for: "j",
        modifiers: .command,
        onProject: nil
    ))
}

@Test func edgeShortcutsUseCommandHomeEndAndPageKeys() {
    #expect(JumpOverlayMonitor.edgeAction(keyCode: 115, modifiers: .command) == .first)
    #expect(JumpOverlayMonitor.edgeAction(keyCode: 119, modifiers: .command) == .last)
    #expect(JumpOverlayMonitor.edgeAction(keyCode: 116, modifiers: .command) == .pageUp)
    #expect(JumpOverlayMonitor.edgeAction(keyCode: 121, modifiers: .command) == .pageDown)
    #expect(JumpOverlayMonitor.edgeAction(keyCode: 115, modifiers: [.command, .option]) == nil)
    #expect(JumpOverlayMonitor.edgeAction(keyCode: 116, modifiers: []) == nil)
    #expect(JumpOverlayMonitor.edgeAction(keyCode: 36, modifiers: .command) == nil)
}

@Test func edgeShortcutDispatchForwardsActionsAndIsConsumedWithoutHandlers() {
    var actions: [String] = []
    #expect(JumpOverlayMonitor.dispatchEdgeShortcut(
        keyCode: 115,
        modifiers: .command,
        onFirst: { actions.append("first") },
        onLast: { actions.append("last") },
        onPage: { actions.append($0 == .next ? "page-down" : "page-up") }
    ))
    #expect(JumpOverlayMonitor.dispatchEdgeShortcut(
        keyCode: 119,
        modifiers: .command,
        onFirst: { actions.append("first") },
        onLast: { actions.append("last") },
        onPage: { actions.append($0 == .next ? "page-down" : "page-up") }
    ))
    #expect(JumpOverlayMonitor.dispatchEdgeShortcut(
        keyCode: 116,
        modifiers: .command,
        onFirst: { actions.append("first") },
        onLast: { actions.append("last") },
        onPage: { actions.append($0 == .next ? "page-down" : "page-up") }
    ))
    #expect(JumpOverlayMonitor.dispatchEdgeShortcut(
        keyCode: 121,
        modifiers: .command,
        onFirst: { actions.append("first") },
        onLast: { actions.append("last") },
        onPage: { actions.append($0 == .next ? "page-down" : "page-up") }
    ))
    #expect(actions == ["first", "last", "page-up", "page-down"])

    #expect(JumpOverlayMonitor.dispatchEdgeShortcut(
        keyCode: 115,
        modifiers: .command,
        onFirst: nil,
        onLast: nil,
        onPage: nil
    ))
    #expect(!JumpOverlayMonitor.dispatchEdgeShortcut(
        keyCode: 36,
        modifiers: .command,
        onFirst: nil,
        onLast: nil,
        onPage: nil
    ))
}
