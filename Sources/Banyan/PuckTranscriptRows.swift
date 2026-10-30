import AppKit
import BanyanCore
import SwiftUI

/// Stable rows for the normalized Puck conversation. Expansion is keyed by
/// timeline item id so streamed text can update in place without closing a
/// disclosure the reader opened.
struct PuckTimelineRows: View {
    let items: [PuckTimelineItem]
    @State private var expandedItemIDs: Set<String>

    init(items: [PuckTimelineItem], initiallyExpandedItemIDs: Set<String> = []) {
        self.items = items
        _expandedItemIDs = State(initialValue: initiallyExpandedItemIDs)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(items) { item in
                PuckTimelineRow(item: item, isExpanded: expansionBinding(for: item.id))
                    .id(item.id)
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
}

struct PuckTimelineRow: View {
    let item: PuckTimelineItem
    @Binding var isExpanded: Bool

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
            Text(text)
                .font(.body)
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
                MarkdownText(text)
                truncationNotice
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Assistant")
        .accessibilityIdentifier(AccessibilityID.puckTimelineItem(item.id))
    }

    private func toolRow(_ tool: PuckToolActivity) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if tool.hasDetails {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded.toggle()
                    }
                } label: {
                    toolHeader(tool)
                }
                .buttonStyle(.banyanPlainLabelOnly)
            } else {
                toolHeader(tool)
            }
            if !isExpanded, let preview = tool.preview {
                outputPreview(preview)
            } else if isExpanded {
                toolDetails(tool)
                    .padding(.leading, 20)
                    .padding(.top, 3)
            }
            if item.truncated || tool.state == .truncated {
                Label("Output was truncated by puckd.", systemImage: "scissors")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.leading, 20)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.puckToolDisclosure(item.id))
    }

    private func toolHeader(_ tool: PuckToolActivity) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            marker("•", emphasis: .secondary)
            Text(tool.actionLabel)
                .font(.callout.weight(.semibold))
                .foregroundStyle(tool.state.presentation.tint)
            Text(tool.name)
                .font(.system(.callout, design: .monospaced))
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
            ForEach(Array(preview.lines.enumerated()), id: \.offset) { index, line in
                HStack(alignment: .top, spacing: 8) {
                    Text(index == 0 ? "└" : " ")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .frame(width: 12, alignment: .leading)
                    Text(line.isEmpty ? " " : line)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if preview.hiddenLineCount > 0 {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded = true
                    }
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
        VStack(alignment: .leading, spacing: 10) {
            if let arguments = tool.arguments, !arguments.isEmpty {
                PuckToolDetailBlock(title: "Arguments", text: arguments, language: "json")
            }
            if !tool.output.isEmpty {
                PuckToolDetailBlock(
                    title: "Output",
                    text: tool.output,
                    language: tool.output.hasPrefix("diff --git") ? "diff" : nil
                )
            } else if tool.state == .running {
                Text("Waiting for the tool result…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if tool.arguments?.isEmpty != false && tool.output.isEmpty && tool.state != .running {
                Text("No arguments or output were captured for this call.")
                    .font(.caption)
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
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
                Text(text)
                    .font(.callout)
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
        VStack(alignment: .leading, spacing: 5) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    marker("•", emphasis: .secondary)
                    Image(systemName: "questionmark.diamond")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Unknown event · \(kind)")
                        .font(.callout)
                        .lineLimit(1)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.banyanPlainLabelOnly)
            if isExpanded {
                PuckToolDetailBlock(title: "Event details", text: detail)
                    .padding(.leading, 20)
                    .padding(.top, 3)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.puckUnknownEvent(item.id))
    }

    private func marker(_ glyph: String, emphasis: HierarchicalShapeStyle) -> some View {
        Text(glyph)
            .font(.system(.body, design: .monospaced).weight(.semibold))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(notices) { notice in
                PuckTimelineNoticeRow(notice: notice)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PuckTimelineNoticeRow: View {
    let notice: PuckTimelineNotice

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
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
                Text(notice.text)
                    .font(.callout)
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

struct PuckToolDetailBlock: View {
    let title: String
    let text: String
    var language: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            CodeBlockView(text: text, language: language, previewHeight: previewHeight)
        }
    }

    private var previewHeight: CGFloat {
        let lineCount = text.split(separator: "\n", omittingEmptySubsequences: false).count
        return min(180, max(40, CGFloat(lineCount) * 18 + 16))
    }
}

private struct PuckToolPreview {
    let lines: [String]
    let hiddenLineCount: Int
}

private extension PuckToolActivity {
    var actionLabel: String {
        switch state {
        case .running: "Running"
        case .succeeded, .truncated: "Ran"
        case .failed: "Failed"
        }
    }

    var hasDetails: Bool {
        arguments?.isEmpty == false || !output.isEmpty
    }

    var preview: PuckToolPreview? {
        let source = output.isEmpty ? (arguments ?? "") : output
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return state == .running
                ? PuckToolPreview(lines: ["Waiting for output…"], hiddenLineCount: 0)
                : nil
        }
        let lines = source.components(separatedBy: .newlines)
        let limit = 3
        return PuckToolPreview(
            lines: Array(lines.prefix(limit)),
            hiddenLineCount: max(0, lines.count - limit)
        )
    }
}

struct PuckToolStatePresentation {
    let label: String
    let systemImage: String
    let tint: Color
}

extension PuckToolState {
    var presentation: PuckToolStatePresentation {
        switch self {
        case .running:
            PuckToolStatePresentation(label: "Running", systemImage: "arrow.triangle.2.circlepath", tint: .blue)
        case .succeeded:
            PuckToolStatePresentation(label: "Succeeded", systemImage: "checkmark.circle.fill", tint: .green)
        case .failed:
            PuckToolStatePresentation(label: "Failed", systemImage: "xmark.octagon.fill", tint: .red)
        case .truncated:
            PuckToolStatePresentation(label: "Truncated", systemImage: "exclamationmark.triangle.fill", tint: .orange)
        }
    }
}

/// Grows towards or away from the live end depending on where the reader was
/// before the content grew. This avoids treating an auto-scroll during
/// streaming as the reader leaving the end, while a genuine upward scroll
/// stops following immediately.
enum PuckTranscriptFollowLogic {
    static func shouldFollow(
        previousAtBottom: Bool,
        previousContentMaxY: CGFloat?,
        currentContentMaxY: CGFloat,
        visibleMaxY: CGFloat,
        tolerance: CGFloat = 24
    ) -> Bool {
        let atBottom = currentContentMaxY - visibleMaxY <= tolerance
        if let previousContentMaxY,
           currentContentMaxY > previousContentMaxY + 0.5,
           previousAtBottom {
            return true
        }
        return atBottom
    }
}

struct PuckTranscriptScrollObserver: NSViewRepresentable {
    let onChange: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> PuckTranscriptScrollObserverView {
        PuckTranscriptScrollObserverView(onChange: onChange)
    }

    func updateNSView(_ nsView: PuckTranscriptScrollObserverView, context: Context) {
        nsView.onChange = onChange
        nsView.refresh()
    }

    static func dismantleNSView(_ nsView: PuckTranscriptScrollObserverView, coordinator: ()) {
        nsView.stopObserving()
    }
}

@MainActor
final class PuckTranscriptScrollObserverView: NSView {
    var onChange: @MainActor (Bool) -> Void
    private weak var scrollView: NSScrollView?
    private weak var documentView: NSView?
    private var lastContentMaxY: CGFloat?
    private var wasAtBottom = true

    init(onChange: @escaping @MainActor (Bool) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refresh()
    }

    override func layout() {
        super.layout()
        refresh()
    }

    func refresh() {
        attachIfNeeded()
        evaluate()
    }

    func stopObserving() {
        NotificationCenter.default.removeObserver(self)
        scrollView = nil
        documentView = nil
        lastContentMaxY = nil
    }

    private func attachIfNeeded() {
        guard let enclosing = findEnclosingScrollView() else { return }
        guard scrollView !== enclosing || documentView !== enclosing.documentView else { return }

        NotificationCenter.default.removeObserver(self)
        scrollView = enclosing
        documentView = enclosing.documentView
        lastContentMaxY = nil

        enclosing.contentView.postsBoundsChangedNotifications = true
        enclosing.postsFrameChangedNotifications = true
        enclosing.documentView?.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollGeometryChanged),
            name: NSView.boundsDidChangeNotification,
            object: enclosing.contentView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollGeometryChanged),
            name: NSView.frameDidChangeNotification,
            object: enclosing
        )
        if let document = enclosing.documentView {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(scrollGeometryChanged),
                name: NSView.frameDidChangeNotification,
                object: document
            )
        }
    }

    private func findEnclosingScrollView() -> NSScrollView? {
        var candidate = superview
        while let view = candidate {
            if let scrollView = view as? NSScrollView { return scrollView }
            candidate = view.superview
        }
        return nil
    }

    @objc private func scrollGeometryChanged() {
        evaluate()
    }

    private func evaluate() {
        guard let scrollView, let documentView = scrollView.documentView else { return }
        let contentMaxY = documentView.bounds.maxY
        let following = PuckTranscriptFollowLogic.shouldFollow(
            previousAtBottom: wasAtBottom,
            previousContentMaxY: lastContentMaxY,
            currentContentMaxY: contentMaxY,
            visibleMaxY: scrollView.documentVisibleRect.maxY
        )
        lastContentMaxY = contentMaxY
        guard following != wasAtBottom else { return }
        wasAtBottom = following
        onChange(following)
    }
}
