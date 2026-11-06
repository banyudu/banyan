import AppKit
import BanyanCore
import Foundation
import SwiftUI

/// Typography shared by the transcript and its editor. Puck content mirrors
/// the terminal font because both surfaces present agent output side by side.
struct PuckTranscriptTypography: Equatable {
    static let fallback = PuckTranscriptTypography(fontFamily: "Menlo", fontSize: 13)

    let fontFamily: String
    let fontSize: Double

    var markdownStyle: MarkdownTextStyle {
        .transcript(fontFamily: resolvedFontFamily, fontSize: fontSize)
    }

    var font: Font {
        resolvedFont(size: fontSize)
    }

    var semiboldFont: Font {
        font.weight(.semibold)
    }

    var detailFontSize: Double {
        max(10, fontSize - 1)
    }

    var detailFont: Font {
        resolvedFont(size: detailFontSize)
    }

    var captionFontSize: Double {
        max(10, fontSize - 2)
    }

    var captionFont: Font {
        resolvedFont(size: captionFontSize)
    }

    var rowSpacing: CGFloat {
        max(18, CGFloat(fontSize) * 1.4)
    }

    var detailLineHeight: CGFloat {
        max(18, CGFloat(detailFontSize) * 1.5)
    }

    private var resolvedFontFamily: String? {
        NSFont(name: fontFamily, size: fontSize) == nil ? nil : fontFamily
    }

    private func resolvedFont(size: Double) -> Font {
        if let resolvedFontFamily {
            return .custom(resolvedFontFamily, size: size)
        }
        return .system(size: size, design: .monospaced)
    }
}

private struct PuckDisclosureHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct PuckAnimatedDisclosure<Content: View>: View {
    let isExpanded: Bool
    @State private var contentHeight: CGFloat = 0
    @State private var isMounted: Bool
    private let content: Content

    init(isExpanded: Bool, @ViewBuilder content: () -> Content) {
        self.isExpanded = isExpanded
        self.content = content()
        _isMounted = State(initialValue: isExpanded)
    }

    var body: some View {
        Group {
            if isExpanded || isMounted {
                content
                    .fixedSize(horizontal: false, vertical: true)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: PuckDisclosureHeightKey.self, value: proxy.size.height)
                        }
                    }
                    .frame(height: isExpanded ? contentHeight : 0, alignment: .top)
                    .clipped()
                    .opacity(isExpanded && contentHeight > 0 ? 1 : 0)
                    .onPreferenceChange(PuckDisclosureHeightKey.self) { height in
                        if abs(height - contentHeight) > 0.5 {
                            contentHeight = height
                        }
                    }
                    .animation(.easeInOut(duration: 0.15), value: contentHeight)
                    .accessibilityHidden(!isExpanded)
            }
        }
        .onChange(of: isExpanded, initial: true) { _, expanded in
            if expanded && !isMounted {
                isMounted = true
            }
        }
        .task(id: isExpanded) {
            guard !isExpanded, isMounted else { return }
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            isMounted = false
        }
    }
}

/// Stable rows for the normalized Puck conversation. Expansion is keyed by
/// timeline item id so streamed text can update in place without closing a
/// disclosure the reader opened.
struct PuckTimelineRows: View {
    let items: [PuckTimelineItem]
    let typography: PuckTranscriptTypography
    private let initiallyExpandedItemIDs: Set<String>
    private let entries: [PuckTranscriptLayout.Entry]
    @State private var expandedItemIDs: Set<String>
    @State private var expandedToolGroupIDs: Set<String>

    init(
        items: [PuckTimelineItem],
        typography: PuckTranscriptTypography = .fallback,
        initiallyExpandedItemIDs: Set<String> = []
    ) {
        let entries = PuckTranscriptLayout.entries(for: items)
        self.items = items
        self.typography = typography
        self.initiallyExpandedItemIDs = initiallyExpandedItemIDs
        self.entries = entries
        _expandedItemIDs = State(initialValue: initiallyExpandedItemIDs)
        _expandedToolGroupIDs = State(initialValue: Set(entries.compactMap { entry in
            guard case .toolGroup(let items) = entry,
                  items.contains(where: { initiallyExpandedItemIDs.contains($0.id) }) else {
                return nil
            }
            return entry.id
        }))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: typography.rowSpacing) {
            ForEach(entries) { entry in
                switch entry {
                case .item(let item):
                    PuckTimelineRow(
                        item: item,
                        typography: typography,
                        isExpanded: expansionBinding(for: item.id)
                    )
                        .id(entry.id)
                case .toolGroup(let items):
                    PuckToolGroupRow(
                        items: items,
                        typography: typography,
                        isExpanded: toolGroupExpansionBinding(for: entry.id),
                        initiallyExpandedItemIDs: initiallyExpandedItemIDs
                    )
                    .id(entry.id)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func expansionBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { expandedItemIDs.contains(id) },
            set: { expanded in
                if expanded {
                    expandedItemIDs.insert(id)
                } else {
                    expandedItemIDs.remove(id)
                }
            }
        )
    }

    private func toolGroupExpansionBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { expandedToolGroupIDs.contains(id) },
            set: { expanded in
                if expanded {
                    expandedToolGroupIDs.insert(id)
                } else {
                    expandedToolGroupIDs.remove(id)
                }
            }
        )
    }
}

enum PuckTranscriptLayout {
    enum Entry: Identifiable, Equatable {
        case item(PuckTimelineItem)
        case toolGroup([PuckTimelineItem])

        var id: String {
            switch self {
            case .item(let item):
                return item.id
            case .toolGroup(let items):
                return "tool-group:\(items.first?.id ?? "empty")"
            }
        }
    }

    static func entries(for items: [PuckTimelineItem]) -> [Entry] {
        var result: [Entry] = []
        var pendingTools: [PuckTimelineItem] = []

        func flushTools() {
            guard !pendingTools.isEmpty else { return }
            result.append(pendingTools.count == 1 ? .item(pendingTools[0]) : .toolGroup(pendingTools))
            pendingTools.removeAll(keepingCapacity: true)
        }

        for item in items {
            if case .tool = item.content {
                if let turnID = item.turnID,
                   let pendingTurnID = pendingTools.last?.turnID,
                   turnID != pendingTurnID {
                    flushTools()
                }
                pendingTools.append(item)
            } else {
                flushTools()
                result.append(.item(item))
            }
        }
        flushTools()
        return result
    }
}

private struct PuckToolGroupRow: View {
    let items: [PuckTimelineItem]
    let typography: PuckTranscriptTypography
    @Binding var isExpanded: Bool
    @State private var expandedItemIDs: Set<String>

    init(
        items: [PuckTimelineItem],
        typography: PuckTranscriptTypography,
        isExpanded: Binding<Bool>,
        initiallyExpandedItemIDs: Set<String> = []
    ) {
        self.items = items
        self.typography = typography
        _isExpanded = isExpanded
        _expandedItemIDs = State(initialValue: initiallyExpandedItemIDs)
    }

    private var summary: PuckToolGroupSummary {
        PuckToolGroupSummary(items: items)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•")
                        .font(typography.semiboldFont)
                        .foregroundStyle(.secondary)
                        .frame(width: 12, alignment: .leading)
                        .accessibilityHidden(true)
                    Text(summary.title)
                        .font(typography.font)
                        .foregroundStyle(summary.tint)
                    if let detail = summary.detail {
                        Text(detail)
                            .font(typography.detailFont)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    if summary.isRunning {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.banyanPlainLabelOnly)

            PuckAnimatedDisclosure(isExpanded: isExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(items) { item in
                        PuckTimelineRow(
                            item: item,
                            typography: typography,
                            isExpanded: expansionBinding(for: item.id)
                        )
                            .id(item.id)
                    }
                }
                .padding(.leading, 20)
                .padding(.top, 8)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(summary.accessibilityLabel)
        .accessibilityIdentifier(AccessibilityID.puckToolGroup(summary.id))
    }

    private func expansionBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { expandedItemIDs.contains(id) },
            set: { expanded in
                if expanded {
                    expandedItemIDs.insert(id)
                } else {
                    expandedItemIDs.remove(id)
                }
            }
        )
    }
}

struct PuckTimelineRow: View {
    let item: PuckTimelineItem
    let typography: PuckTranscriptTypography
    @Binding var isExpanded: Bool

    init(
        item: PuckTimelineItem,
        typography: PuckTranscriptTypography = .fallback,
        isExpanded: Binding<Bool>
    ) {
        self.item = item
        self.typography = typography
        _isExpanded = isExpanded
    }

    @ViewBuilder
    var body: some View {
        switch item.content {
        case .user(let text):
            userRow(text)
        case .assistant(let text):
            assistantRow(text)
        case .tool(let tool):
            toolRow(tool)
        case .error(let text):
            calloutRow(
                title: "Error",
                systemImage: "exclamationmark.triangle.fill",
                tint: .red,
                text: text
            )
        case .interruption(let text):
            calloutRow(
                title: "Interrupted",
                systemImage: "stop.circle.fill",
                tint: .orange,
                text: text
            )
        case .unknown(let kind, let detail):
            unknownRow(kind: kind, detail: detail)
        }
    }

    private func userRow(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            marker("›", emphasis: .secondary)
            SessionLinkedText(text)
                .font(typography.font)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.075), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("You")
        .accessibilityIdentifier(AccessibilityID.puckTimelineItem(item.id))
    }

    private func assistantRow(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            marker("•", emphasis: .secondary)
            VStack(alignment: .leading, spacing: 6) {
                MarkdownText(text, style: typography.markdownStyle)
                truncationNotice
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Assistant")
        .accessibilityIdentifier(AccessibilityID.puckTimelineItem(item.id))
    }

    private func toolRow(_ tool: PuckToolActivity) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if tool.hasDetails {
                Button {
                    isExpanded.toggle()
                } label: {
                    toolHeader(tool)
                }
                .buttonStyle(.banyanPlainLabelOnly)
            } else {
                toolHeader(tool)
            }
            if tool.hasDetails {
                if let preview = tool.preview {
                    PuckAnimatedDisclosure(isExpanded: !isExpanded) {
                        outputPreview(preview)
                            .padding(.top, 5)
                    }
                }
                PuckAnimatedDisclosure(isExpanded: isExpanded) {
                    toolDetails(tool)
                        .padding(.leading, 20)
                        .padding(.top, 8)
                }
            } else if let preview = tool.preview {
                outputPreview(preview)
                    .padding(.top, 5)
            }
            if item.truncated || tool.state == .truncated {
                Label("Output was truncated by puckd.", systemImage: "scissors")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
                    .padding(.top, 5)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.puckToolDisclosure(item.id))
    }

    private func toolHeader(_ tool: PuckToolActivity) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            marker("•", emphasis: .secondary)
            Text(tool.actionLabel)
                .font(typography.font)
                .foregroundStyle(tool.state.presentation.tint)
            SessionLinkedText(tool.displayTitle)
                .font(typography.font)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if tool.state == .running {
                ProgressView()
                    .controlSize(.mini)
            }
            if tool.hasDetails {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
        }
        .contentShape(Rectangle())
    }

    private func outputPreview(_ preview: PuckToolPreview) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if preview.language != nil || preview.syntaxSections != nil {
                HStack(alignment: .top, spacing: 8) {
                    Text("└")
                        .font(typography.detailFont)
                        .foregroundStyle(.tertiary)
                        .frame(width: 12, alignment: .leading)
                    CodeBlockView(
                        text: preview.lines.joined(separator: "\n"),
                        language: preview.language?.rawValue,
                        syntaxSections: preview.syntaxSections,
                        font: typography.font,
                        previewHeight: CGFloat(preview.lines.count) * typography.detailLineHeight + 16,
                        showsHeader: false,
                        detectsLinks: true
                    )
                    .opacity(0.75)
                }
            } else {
                ForEach(Array(preview.lines.enumerated()), id: \.offset) { index, line in
                    HStack(alignment: .top, spacing: 8) {
                        Text(index == 0 ? "└" : " ")
                            .font(typography.detailFont)
                            .foregroundStyle(.tertiary)
                            .frame(width: 12, alignment: .leading)
                        SessionLinkedText(line.isEmpty ? " " : line)
                            .font(typography.font)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            if preview.hiddenLineCount > 0 {
                Button {
                    isExpanded = true
                } label: {
                    Text("+\(preview.hiddenLineCount) lines")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.banyanBorderless)
                .padding(.leading, 20)
            }
        }
        .padding(.leading, 4)
    }

    @ViewBuilder
    private func toolDetails(_ tool: PuckToolActivity) -> some View {
        let output = tool.displayOutput
        VStack(alignment: .leading, spacing: 10) {
            if let arguments = tool.arguments, !arguments.isEmpty {
                PuckToolDetailBlock(
                    title: "Arguments",
                    text: arguments,
                    language: "json",
                    typography: typography
                )
            }
            if !output.isEmpty {
                PuckToolDetailBlock(
                    title: "Output",
                    text: output,
                    language: output.hasPrefix("diff --git") ? "diff" : nil,
                    typography: typography
                )
            } else if tool.state == .running {
                Text("Waiting for the tool result…")
                    .font(typography.detailFont)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if tool.arguments?.isEmpty != false && output.isEmpty && tool.state != .running {
                Text("No arguments or output were captured for this call.")
                    .font(typography.detailFont)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func calloutRow(title: String, systemImage: String, tint: Color, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .font(.caption)
                .foregroundStyle(tint)
                .frame(width: 12)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(typography.captionFont.weight(.bold))
                    .foregroundStyle(tint)
                SessionLinkedText(text)
                    .font(typography.font)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                truncationNotice
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.puckTimelineItem(item.id))
    }

    private func unknownRow(kind: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    marker("•", emphasis: .secondary)
                    Image(systemName: "questionmark.diamond")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Unknown event · \(kind)")
                        .font(typography.font)
                        .lineLimit(1)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.banyanPlainLabelOnly)
            PuckAnimatedDisclosure(isExpanded: isExpanded) {
                PuckToolDetailBlock(
                    title: "Event details",
                    text: detail,
                    typography: typography
                )
                    .padding(.leading, 20)
                    .padding(.top, 8)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.puckUnknownEvent(item.id))
    }

    private func marker(_ glyph: String, emphasis: HierarchicalShapeStyle) -> some View {
        Text(glyph)
            .font(typography.semiboldFont)
            .foregroundStyle(emphasis)
            .frame(width: 12, alignment: .leading)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var truncationNotice: some View {
        if item.truncated {
            Label("Preview truncated by puckd.", systemImage: "scissors")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct PuckTimelineNotices: View {
    let notices: [PuckTimelineNotice]
    var typography: PuckTranscriptTypography = .fallback

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(notices) { notice in
                PuckTimelineNoticeRow(notice: notice, typography: typography)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PuckTimelineNoticeRow: View {
    let notice: PuckTimelineNotice
    let typography: PuckTranscriptTypography

    private var tint: Color {
        notice.role == .interruption ? .orange : .red
    }

    private var systemImage: String {
        notice.role == .interruption ? "stop.circle.fill" : "exclamationmark.triangle.fill"
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .font(.caption)
                .foregroundStyle(tint)
                .frame(width: 12)
            VStack(alignment: .leading, spacing: 4) {
                Text(notice.title)
                    .font(typography.captionFont.weight(.bold))
                    .foregroundStyle(tint)
                SessionLinkedText(notice.text)
                    .font(typography.font)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if notice.truncated {
                    Label("Preview truncated by puckd.", systemImage: "scissors")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.puckTimelineNotice(notice.id))
    }
}
