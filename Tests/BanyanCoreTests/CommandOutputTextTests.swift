import Foundation
import Testing
@testable import BanyanCore

/// These exist because the ANSI pattern was written inside a raw string as
/// `#"\u{001B}..."#`. Swift leaves escapes alone in a raw string, so ICU received the
/// literal characters `\u{001B}` and rejected the whole pattern — it never compiled.
/// Behind `try?` that failed silently and the helper returned its input untouched for
/// the pattern's entire life; behind `try!` it trapped in the regex's one-time
/// initializer and crashed the app on a 20-second timer.
///
/// So these assert on behaviour, not on the literal: they fail for either spelling of
/// the bug. The implementation is now shared, so this is the only copy needed.
private let esc = "\u{001B}"

@Test func ansiEscapePatternCompiles() {
    // Touching the regex at all is what used to trap.
    #expect(CommandOutputText.ansiEscapeRegex.numberOfCaptureGroups == 0)
}

@Test func stripsColorCodes() {
    let coloured = "\(esc)[31mERROR\(esc)[0m: something failed"
    #expect(CommandOutputText.strippingANSIEscapes(coloured) == "ERROR: something failed")
}

@Test func stripsCursorAndClearSequences() {
    let noisy = "\(esc)[2J\(esc)[Hloading\(esc)[1;32m done\(esc)[m"
    #expect(CommandOutputText.strippingANSIEscapes(noisy) == "loading done")
}

@Test func leavesPlainTextAlone() {
    let plain = "ENG-1234 · a normal title with [brackets] and 0-9"
    #expect(CommandOutputText.strippingANSIEscapes(plain) == plain)
}

@Test func leavesJSONPayloadIntact() {
    // Linear CLI output is parsed as JSON downstream, so stripping must not disturb it.
    let payload = #"{"identifier":"ENG-1","title":"a [b] c 0-9"}"#
    #expect(CommandOutputText.strippingANSIEscapes(payload) == payload)
}

@Test func stripsWrappersFromRealLinearCliOutput() {
    // A title arriving with SGR wrappers must come back usable, not with escape bytes
    // embedded — that is what silently leaked into session context before.
    let output = "\(esc)[1;34mENG-8838\(esc)[0m  Fix the sidebar hang"
    let cleaned = CommandOutputText.strippingANSIEscapes(output)
    #expect(cleaned == "ENG-8838  Fix the sidebar hang")
    #expect(!cleaned.contains(esc))
}
