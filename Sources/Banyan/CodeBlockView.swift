import AppKit
import BanyanCore
import SwiftUI

struct CodeBlockView: View {
    private let displayText: String
    private let requestedLanguage: String?
    private let language: CodeBlockLanguage?
    private let font: Font
    private let minimumHeight: CGFloat
    private let previewHeight: CGFloat
    private let showsHeader: Bool

    @State private var isExpanded = false
    @State private var copied = false
    @State private var highlighted: HighlightedCode?

    init(
        text: String,
        language: String? = nil,
        font: Font = .system(.caption, design: .monospaced),
        minimumHeight: CGFloat = 30,
        previewHeight: CGFloat = 220,
        showsHeader: Bool = true
    ) {
        self.displayText = CodexConversationText.plain(text)
        self.requestedLanguage = language
        self.language = CodeBlockLanguage(identifier: language)
        self.font = font
        self.minimumHeight = minimumHeight
        self.previewHeight = previewHeight
        self.showsHeader = showsHeader
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsHeader {
                header
                Divider()
            }
            codeContent
        }
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.quaternary.opacity(0.8), lineWidth: 1)
        }
        .task(id: highlightRequest) {
            await loadHighlight()
        }
        .onChange(of: canExpand) { _, canExpand in
            if !canExpand { isExpanded = false }
        }
        .accessibilityIdentifier(AccessibilityID.codeBlock)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(languageLabel)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(action: copy) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(copied ? "Copied" : "Copy code")
            .accessibilityLabel(copied ? "Copied" : "Copy code")
            .accessibilityIdentifier(AccessibilityID.codeBlockCopy)

            if canExpand {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(isExpanded ? "Collapse code" : "Expand code")
                .accessibilityLabel(isExpanded ? "Collapse code" : "Expand code")
                .accessibilityIdentifier(AccessibilityID.codeBlockExpand)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private var codeContent: some View {
        if isExpanded {
            ScrollView(.horizontal) {
                textContent
            }
            .frame(minHeight: minimumHeight)
        } else {
            ScrollView([.horizontal, .vertical]) {
                textContent
            }
            .frame(minHeight: minimumHeight, maxHeight: previewHeight)
        }
    }

    private var textContent: some View {
        Group {
            if let highlightedText {
                Text(highlightedText)
            } else {
                Text(displayText)
            }
        }
        .font(font)
        .textSelection(.enabled)
        .fixedSize(horizontal: true, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
    }

    private var highlightedText: AttributedString? {
        guard let highlighted,
              highlighted.request == highlightRequest else {
            return nil
        }
        return highlighted.value
    }

    private var highlightRequest: CodeBlockHighlightRequest? {
        guard let language, CodeBlockHighlightPolicy.canHighlight(displayText) else { return nil }
        return CodeBlockHighlightRequest(text: displayText, language: language)
    }

    private var canExpand: Bool {
        CodeBlockHighlightPolicy.needsExpansion(displayText)
    }

    private var languageLabel: String {
        if let language { return language.displayName }
        guard let requestedLanguage,
              let token = requestedLanguage
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: { $0.isWhitespace })
                .first else {
            return "TEXT"
        }
        return String(token)
    }

    private func loadHighlight() async {
        guard let request = highlightRequest else {
            highlighted = nil
            return
        }
        let value = await CodeBlockHighlightCache.shared.highlighted(for: request)
        guard !Task.isCancelled else { return }
        highlighted = value.map { HighlightedCode(request: request, value: $0) }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(displayText, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }
}
private struct HighlightedCode {
    let request: CodeBlockHighlightRequest
    let value: AttributedString
}

private struct CodeBlockHighlightRequest: Hashable, Sendable {
    let text: String
    let language: CodeBlockLanguage
}

private actor CodeBlockHighlightCache {
    static let shared = CodeBlockHighlightCache()

    private var values: [CodeBlockHighlightRequest: AttributedString] = [:]
    private var order: [CodeBlockHighlightRequest] = []

    func highlighted(for request: CodeBlockHighlightRequest) -> AttributedString? {
        if let cached = values[request] {
            touch(request)
            return cached
        }
        guard let spans = CodeBlockSyntaxHighlighter.highlight(request.text, language: request.language) else {
            return nil
        }

        var result = AttributedString()
        for span in spans {
            var part = AttributedString(span.text)
            if let kind = span.kind {
                part.foregroundColor = kind.color
            }
            result.append(part)
        }

        if values.count >= CodeBlockHighlightPolicy.cacheEntries, let oldest = order.first {
            values[oldest] = nil
            order.removeFirst()
        }
        values[request] = result
        order.append(request)
        return result
    }

    private func touch(_ request: CodeBlockHighlightRequest) {
        guard let index = order.firstIndex(of: request) else { return }
        order.remove(at: index)
        order.append(request)
    }
}

private extension SyntaxHighlightKind {
    var color: Color {
        switch self {
        case .keyword: return .pink
        case .string: return .green
        case .comment: return .secondary
        case .number: return .orange
        case .literal: return .purple
        case .attribute: return .yellow
        case .key: return .blue
        case .tag: return .purple
        case .added: return .green
        case .removed: return .red
        case .hunk: return .blue
        }
    }
}
