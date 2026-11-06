import AppKit
import SwiftTerm
import SwiftUI
import Testing
@testable import Banyan

@Suite @MainActor
struct SessionTextLinksTests {
    @Test(arguments: [
        "See TASK-123 and #456.",
        "Open https://example.com/TASK-123#456 then docs/report.md",
        "Files: /tmp/report.txt ~/notes/todo.md ../README.md",
        "Skip id#45 #ff0000 #123abc $TASK-123",
    ])
    func nativeTextAndTerminalDetectTheSameReferences(text: String) throws {
        let view = DetectingLocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 1_800, height: 100))
        let terminal = try #require(view.terminal)
        terminal.resize(cols: 200, rows: 3)
        terminal.feed(text: text)
        let terminalRanges = terminal.implicitLinkRowRanges(row: 0)
        let native = SessionTextLinks.annotate(AttributedString(text), environment: [:], includesSessionReferences: true)
        let nativeTexts = native.runs.filter { $0.link != nil }.map { String(native[$0.range].characters) }
        let characters = Array(text)
        #expect(nativeTexts == terminalRanges.map { String(characters[$0]) })
    }

    @Test func plainOutputKeepsMarkdownAndSyntaxWhileAddingLinks() {
        let text = "**TASK-123**\n{\"url\":\"https://example.com/report\",\"issue\":\"#456\"}"
        var original = AttributedString(text)
        original.foregroundColor = .orange
        let result = SessionTextLinks.annotate(original, environment: ["BANYAN_LINEAR_ORG": "example"],
                                               includesSessionReferences: true)
        #expect(String(result.characters) == text)
        #expect(result.runs.filter { $0.link != nil }.map { String(result[$0.range].characters) }
            == ["TASK-123", "https://example.com/report", "#456"])
        #expect(result.runs.filter { $0.link == nil }.allSatisfy { $0.foregroundColor == .orange })
        #expect(result.runs.allSatisfy { $0.inlinePresentationIntent == nil })
    }

    @Test func markdownPreservesExplicitDestinationsAndLinksBareReferences() {
        let result = MarkdownInlineText.parse(
            "**#123** [TASK-456](https://example.com/original) [file](docs/a%20b.md) `docs/TASK-789.md`",
            environment: [:], includesSessionReferences: true
        )
        let linkedRuns = result.runs.filter { $0.link != nil }
        let urls = linkedRuns.compactMap { $0.link?.absoluteString }
        #expect(linkedRuns.count == 4)
        #expect(urls.contains("https://example.com/original"))
        #expect(urls.contains("docs/a%20b.md"))
        #expect(linkedRuns.map { String(result[$0.range].characters) }.contains("docs/TASK-789.md"))
        #expect(linkedRuns.first?.inlinePresentationIntent?.contains(.stronglyEmphasized) == true)
    }
}
