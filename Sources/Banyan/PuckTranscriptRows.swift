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
        VStack(alignment: .leading, spacing: 16) {
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
        HStack(alignment: .top, spacing: 10) {
            roleIcon("person.crop.circle.fill", tint: .accentColor, label: "You")
            VStack(alignment: .leading, spacing: 6) {
                roleTitle("You", tint: .accentColor)
                Text(text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.puckTimelineItem(item.id))
    }

    private func assistantRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            roleIcon("sparkles", tint: .secondary, label: "Assistant")
            VStack(alignment: .leading, spacing: 7) {
                roleTitle("Assistant", tint: .secondary)
                MarkdownText(text)
                truncationNotice
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.puckTimelineItem(item.id))
    }

    private func toolRow(_ tool: PuckToolActivity) -> some View {
        DisclosureGroup(isExpanded: $isExpanded) {
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
                if item.truncated || tool.state == .truncated {
                    Label("Output was truncated by puckd.", systemImage: "scissors")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.top, 10)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(tool.name)
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                PuckToolStateBadge(state: tool.state)
            }
        }
        .tint(.secondary)
        .padding(10)
        .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.quaternary.opacity(0.8), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.puckToolDisclosure(item.id))
    }

    private func calloutRow(title: String, systemImage: String, tint: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .frame(width: 18)
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
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(tint.opacity(0.28), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.puckTimelineItem(item.id))
    }

    private func unknownRow(kind: String, detail: String) -> some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            PuckToolDetailBlock(title: "Event details", text: detail)
                .padding(.top, 8)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.diamond")
                    .foregroundStyle(.secondary)
                Text("Unknown event · \(kind)")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("Details")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .tint(.secondary)
        .padding(10)
        .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.quaternary.opacity(0.8), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.puckUnknownEvent(item.id))
    }

    private func roleIcon(_ systemImage: String, tint: Color, label: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 20, height: 22)
            .accessibilityLabel(label)
    }

    private func roleTitle(_ title: String, tint: Color) -> some View {
        Text(title)
            .font(.caption.weight(.bold))
            .foregroundStyle(tint)
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
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .frame(width: 18)
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
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(tint.opacity(0.28), lineWidth: 1)
        }
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
            CodeBlockView(text: text, language: language, previewHeight: 180)
        }
    }
}

private struct PuckToolStateBadge: View {
    let state: PuckToolState

    var body: some View {
        Label(state.presentation.label, systemImage: state.presentation.systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(state.presentation.tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(state.presentation.tint.opacity(0.12), in: Capsule())
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
