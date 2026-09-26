@testable import Banyan
import AppKit
import Testing

/// The suggestion banner is answered from the keyboard with `⌘⇧↩` (run) and
/// `⌘⇧⌫` (dismiss). The matcher is deliberately strict: the chord only fires
/// with Command+Shift and nothing else, so it cannot shadow plain `↩` in the
/// terminal or the already-bound `⌘↩` (Start Selected Linear Issue).
@Test func suggestionShortcutsMatchCommandShiftReturnAndDelete() {
    #expect(SuggestionShortcuts.matches(
        keyCode: 36, modifiers: [.command, .shift], isRepeat: false
    ) == .approve)
    #expect(SuggestionShortcuts.matches(
        keyCode: 76, modifiers: [.command, .shift], isRepeat: false
    ) == .approve)
    #expect(SuggestionShortcuts.matches(
        keyCode: 51, modifiers: [.command, .shift], isRepeat: false
    ) == .dismiss)
    #expect(SuggestionShortcuts.matches(
        keyCode: 117, modifiers: [.command, .shift], isRepeat: false
    ) == .dismiss)
}

@Test func suggestionShortcutsRequireBothCommandAndShift() {
    #expect(SuggestionShortcuts.matches(keyCode: 36, modifiers: [], isRepeat: false) == nil)
    #expect(SuggestionShortcuts.matches(keyCode: 36, modifiers: [.command], isRepeat: false) == nil)
    #expect(SuggestionShortcuts.matches(keyCode: 36, modifiers: [.shift], isRepeat: false) == nil)
    #expect(SuggestionShortcuts.matches(keyCode: 51, modifiers: [.command], isRepeat: false) == nil)
}

@Test func suggestionShortcutsIgnoreExtraModifiersRepeatsAndOtherKeys() {
    #expect(SuggestionShortcuts.matches(
        keyCode: 36, modifiers: [.command, .shift, .option], isRepeat: false
    ) == nil)
    #expect(SuggestionShortcuts.matches(
        keyCode: 36, modifiers: [.command, .shift, .control], isRepeat: false
    ) == nil)
    #expect(SuggestionShortcuts.matches(
        keyCode: 36, modifiers: [.command, .shift], isRepeat: true
    ) == nil)
    #expect(SuggestionShortcuts.matches(
        keyCode: 48, modifiers: [.command, .shift], isRepeat: false
    ) == nil)
}
