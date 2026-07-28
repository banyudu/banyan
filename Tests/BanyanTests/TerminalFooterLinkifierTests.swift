import Testing
@testable import Banyan

@Test func terminalFooterLinkifierAnnotatesPullRequestReferences() {
    let annotated = TerminalFooterLinkifier.annotate("PR #6965")

    #expect(annotated.contains("PR #6965"))
    #expect(annotated.contains("\u{001B}]8;;banyan-pr://6965\u{0007}"))
    #expect(annotated.hasSuffix("\u{001B}]8;;\u{0007}"))
}

@Test func terminalFooterLinkifierExtractsPullRequestNumber() {
    #expect(TerminalFooterLinkifier.pullRequestNumber(in: "banyan-pr://6965") == 6965)
    #expect(TerminalFooterLinkifier.pullRequestNumber(in: "https://github.com/2enai/clawly/pull/6965") == nil)
}

@Test func terminalFooterLinkifierAnnotatesAcrossNonUTF8Bytes() {
    let bytes: [UInt8] = [0xF0, 0x9F, 0x92, 0xAC] + Array(" · PR #6965".utf8)
    let annotated = TerminalFooterLinkifier.annotate(bytes[...])
    #expect(String(decoding: annotated, as: UTF8.self).contains("banyan-pr://6965"))
}
