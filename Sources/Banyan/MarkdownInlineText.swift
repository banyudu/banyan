import BanyanCore
import SwiftUI

private struct MarkdownLinkEnvironmentKey: EnvironmentKey {
    static let defaultValue = ProcessInfo.processInfo.environment
}

extension EnvironmentValues {
    var markdownLinkEnvironment: [String: String] {
        get { self[MarkdownLinkEnvironmentKey.self] }
        set { self[MarkdownLinkEnvironmentKey.self] = newValue }
    }
}

enum MarkdownInlineText {
    private static let linkDetector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func parse(_ value: String, environment: [String: String]) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        var attributed = (try? AttributedString(markdown: value, options: options))
            ?? AttributedString(value)
        let text = String(attributed.characters)
        let issueRanges = LinearIssueReference.issueIDRanges(in: text)
        guard !issueRanges.isEmpty else { return attributed }

        // Code spans can contain URLs that Markdown leaves unlinked. Do not
        // replace only the issue-shaped part of one with a different destination.
        let urlRanges = linkDetector.matches(in: text, range: NSRange(text.startIndex..., in: text)).map(\.range)
        for range in issueRanges {
            guard !urlRanges.contains(where: { NSIntersectionRange($0, NSRange(range, in: text)).length > 0 }),
                  let start = AttributedString.Index(range.lowerBound, within: attributed),
                  let end = AttributedString.Index(range.upperBound, within: attributed),
                  attributed[start..<end].runs.allSatisfy({ $0.link == nil }) else {
                continue
            }
            attributed[start..<end].link = URL(string: LinearIssueReference.issueURL(
                for: String(text[range]), environment: environment
            ))
        }
        return attributed
    }
}
