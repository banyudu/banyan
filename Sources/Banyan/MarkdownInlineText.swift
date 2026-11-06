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
    static func parse(
        _ value: String, environment: [String: String], includesSessionReferences: Bool = false
    ) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        let attributed = (try? AttributedString(markdown: value, options: options))
            ?? AttributedString(value)
        return SessionTextLinks.annotate(attributed, environment: environment,
                                         includesSessionReferences: includesSessionReferences)
    }
}
