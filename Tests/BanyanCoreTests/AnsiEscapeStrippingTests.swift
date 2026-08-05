import Foundation
import Testing
@testable import BanyanCore

/// These exist because the ANSI pattern was written inside a raw string as
/// `#"\u{001B}..."#`. Swift leaves escapes alone in a raw string, so ICU received the
/// literal characters `\u{001B}` and rejected the whole pattern — it never compiled.
/// Behind `try?` that failed silently and `cleanCommandOutput` returned its input
/// untouched for the pattern's entire life; behind `try!` it crashed the app on a
/// 20-second timer. Asserting on behaviour catches both spellings of the bug.

private let esc = "\u{001B}"

@Test func ansiEscapePatternCompiles() {
    // Constructing the regex at all is the thing that used to trap.
    #expect(SessionContextResolver.ansiEscapeRegex.numberOfCaptureGroups == 0)
}

@Test func cleanCommandOutputStripsColorCodes() {
    let coloured = "\(esc)[31mERROR\(esc)[0m: something failed"
    #expect(SessionContextResolver.cleanCommandOutput(coloured) == "ERROR: something failed")
}

@Test func cleanCommandOutputStripsCursorAndClearSequences() {
    let noisy = "\(esc)[2J\(esc)[Hloading\(esc)[1;32m done\(esc)[m"
    #expect(SessionContextResolver.cleanCommandOutput(noisy) == "loading done")
}

@Test func cleanCommandOutputLeavesPlainTextAlone() {
    let plain = "ENG-1234 · a normal title with [brackets] and 0-9"
    #expect(SessionContextResolver.cleanCommandOutput(plain) == plain)
}

@Test func cleanCommandOutputHandlesRealLinearCliOutput() {
    // A title arriving with SGR wrappers must come back usable, not with escape
    // bytes embedded — that is what silently leaked into session context before.
    let output = "\(esc)[1mFix the sidebar hang\(esc)[0m"
    let cleaned = SessionContextResolver.cleanCommandOutput(output)
    #expect(cleaned == "Fix the sidebar hang")
    #expect(!cleaned.contains(esc))
}
