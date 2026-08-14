import Foundation
import Testing
@testable import Banyan

@MainActor
@Test func terminalLinkURLTurnsAbsolutePathIntoFileURL() {
    let url = BanyanSession.terminalLinkURL("/Users/example/math-worksheets/worksheet.pdf")

    #expect(url == URL(fileURLWithPath: "/Users/example/math-worksheets/worksheet.pdf"))
    #expect(url?.isFileURL == true)
}

@MainActor
@Test func terminalLinkURLAcceptsWebURLsButRejectsRelativePaths() {
    #expect(BanyanSession.terminalLinkURL("https://example.com/path")?.absoluteString == "https://example.com/path")
    #expect(BanyanSession.terminalLinkURL("notes/worksheet.pdf") == nil)
}
