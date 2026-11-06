import SwiftUI
import SwiftTerm

private struct SessionLinkContextKey: EnvironmentKey {
    static let defaultValue: SessionLinkContext? = nil
}

extension EnvironmentValues {
    var sessionLinkContext: SessionLinkContext? {
        get { self[SessionLinkContextKey.self] }
        set { self[SessionLinkContextKey.self] = newValue }
    }
}

private struct SessionLinksModifier: ViewModifier {
    let context: SessionLinkContext
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        content
            .environment(\.sessionLinkContext, context)
            .environment(\.markdownLinkEnvironment, context.environment)
            .environment(\.openURL, OpenURLAction { url in
                SessionLinkResolver.open(.url(url), context: context) { openURL($0) }
                return .handled
            })
    }
}

extension View {
    func sessionLinks(context: SessionLinkContext) -> some View {
        modifier(SessionLinksModifier(context: context))
    }
}

/// Adds links without interpreting Markdown in user messages or tool output.
struct SessionLinkedText: View {
    @Environment(\.sessionLinkContext) private var context
    @Environment(\.markdownLinkEnvironment) private var environment
    private let text: AttributedString

    init(_ text: String) { self.text = AttributedString(text) }
    init(_ text: AttributedString) { self.text = text }

    var body: some View {
        Text(SessionTextLinks.annotate(text, environment: environment, includesSessionReferences: context != nil))
    }
}

enum SessionTextLinks {
    static func annotate(
        _ value: AttributedString,
        environment: [String: String],
        includesSessionReferences: Bool
    ) -> AttributedString {
        var result = value
        let text = String(value.characters)
        for range in Terminal.implicitLinkRanges(in: text) {
            let reference = String(text[range])
            guard includesSessionReferences || SessionLinkResolver.linearIssueID(in: reference) != nil,
                  let start = AttributedString.Index(range.lowerBound, within: result),
                  let end = AttributedString.Index(range.upperBound, within: result),
                  result[start..<end].runs.allSatisfy({ $0.link == nil }),
                  let url = SessionLinkResolver.referenceURL(reference, environment: environment) else { continue }
            result[start..<end].link = url
            result[start..<end].foregroundColor = .accentColor
        }
        return result
    }
}
