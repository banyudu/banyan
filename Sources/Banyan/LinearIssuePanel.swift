import AppKit
import SwiftUI

struct LinearIssuePanel: View {
    let context: SessionContextInfo
    let issue: LinearIssueDetails?
    let loadState: LinearIssueLoadState
    let onRefresh: () -> Void
    let onOpen: () -> Void
    let onChangeState: (LinearWorkflowState) -> Void
    @State private var selectedStateID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            Divider()

            content
        }
        .frame(width: 360)
        .background(.regularMaterial)
        .accessibilityIdentifier(AccessibilityID.linearIssuePanel)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "list.bullet.rectangle")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(issue?.identifier ?? context.linearIssueID ?? "Linear")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier(AccessibilityID.linearIssueRefreshButton)
            .help("Refresh Linear issue")

            Button(action: onOpen) {
                Image(systemName: "arrow.up.forward.square")
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier(AccessibilityID.linearIssueOpenButton)
            .help("Open in Linear")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .idle:
            placeholder("No Linear issue")
        case .loading:
            loadingView("Loading issue...")
        case let .updating(stateName):
            loadingView("Moving to \(stateName)...")
        case let .failed(message):
            VStack(alignment: .leading, spacing: 12) {
                placeholder(message)
                Button("Retry", action: onRefresh)
                    .buttonStyle(.bordered)
            }
            .padding(14)
        case .loaded:
            if let issue {
                issueContent(issue)
            } else {
                placeholder("No issue details")
            }
        }
    }

    private func issueContent(_ issue: LinearIssueDetails) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(issue.title)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

                metadataGrid(issue)

                if !issue.workflowStates.isEmpty {
                    HStack(spacing: 8) {
                        sectionTitle("Status")
                            .frame(width: 54, alignment: .leading)
                        Picker("Status", selection: statusSelectionBinding(issue)) {
                            ForEach(issue.workflowStates) { state in
                                Label {
                                    Text(state.name)
                                } icon: {
                                    Circle()
                                        .fill(Color.linearHex(state.color))
                                }
                                .tag(state.id)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .controlSize(.small)
                        .disabled(loadState.isBusy)
                        .help("Change Linear status")
                    }
                }

                if let description = issue.description?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !description.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        sectionTitle("Description")
                        MarkdownText(description)
                            .font(.callout)
                    }
                }

                if !issue.labels.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        sectionTitle("Labels")
                        FlowLayout(spacing: 6) {
                            ForEach(issue.labels) { label in
                                HStack(spacing: 5) {
                                    Circle()
                                        .fill(Color.linearHex(label.color))
                                        .frame(width: 6, height: 6)
                                    Text(label.name)
                                        .lineLimit(1)
                                }
                                .font(.caption)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(.quaternary, in: Capsule())
                            }
                        }
                    }
                }

                if !issue.attachments.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        sectionTitle("Links")
                        ForEach(issue.attachments) { attachment in
                            Button {
                                if let url = URL(string: attachment.url) {
                                    NSWorkspace.shared.open(url)
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "link")
                                    Text(attachment.title)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.primary)
                        }
                    }
                }

                if !issue.comments.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("Recent Comments")
                        ForEach(issue.comments) { comment in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(comment.userName ?? "Unknown")
                                    .font(.caption.weight(.semibold))
                                MarkdownText(comment.body)
                                    .font(.caption)
                                    .lineLimit(8)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .padding(14)
        }
        .onAppear {
            selectedStateID = issue.state.id
        }
        .onChange(of: issue.state.id) { _, newValue in
            selectedStateID = newValue
        }
    }

    private func statusSelectionBinding(_ issue: LinearIssueDetails) -> Binding<String> {
        Binding {
            selectedStateID ?? issue.state.id
        } set: { newValue in
            selectedStateID = newValue
            guard newValue != issue.state.id,
                  let state = issue.workflowStates.first(where: { $0.id == newValue }) else {
                return
            }
            onChangeState(state)
        }
    }

    private func metadataGrid(_ issue: LinearIssueDetails) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            metadataRow("Assignee", issue.assigneeName)
            metadataRow("Project", issue.projectName)
            metadataRow("Cycle", issue.cycleName)
            metadataRow("Team", issue.teamName)
            if let priority = issue.priority, priority > 0 {
                metadataRow("Priority", "P\(priority)")
            }
            if let estimate = issue.estimate {
                metadataRow("Estimate", "\(estimate)")
            }
        }
        .font(.caption)
    }

    @ViewBuilder
    private func metadataRow(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(spacing: 8) {
                Text(label)
                    .foregroundStyle(.secondary)
                    .frame(width: 54, alignment: .leading)
                Text(value)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func loadingView(_ message: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(message)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func placeholder(_ message: String) -> some View {
        Text(message)
            .foregroundStyle(.secondary)
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var headerSubtitle: String {
        switch loadState {
        case .idle:
            return "Not detected"
        case .loading:
            return "Loading"
        case let .updating(stateName):
            return "Moving to \(stateName)"
        case .loaded:
            return issue?.state.name ?? "Loaded"
        case .failed:
            return "Needs Linear auth"
        }
    }
}

private struct MarkdownText: View {
    let value: String

    init(_ value: String) {
        self.value = value
    }

    var body: some View {
        text
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private var text: Text {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let attributed = try? AttributedString(markdown: value, options: options) {
            return Text(attributed)
        }
        return Text(value)
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        guard width > 0 else {
            return CGSize(width: 0, height: 0)
        }
        let rows = rows(in: width, subviews: subviews)
        return CGSize(width: width, height: rows.last.map { $0.maxY } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in rows(in: bounds.width, subviews: subviews) {
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: bounds.minX + item.x, y: bounds.minY + row.y),
                    proposal: ProposedViewSize(item.size)
                )
            }
        }
    }

    private func rows(in width: CGFloat, subviews: Subviews) -> [FlowRow] {
        var rows: [FlowRow] = []
        var currentItems: [FlowItem] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var currentHeight: CGFloat = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if currentX > 0, currentX + size.width > width {
                rows.append(FlowRow(y: currentY, height: currentHeight, items: currentItems))
                currentY += currentHeight + spacing
                currentItems = []
                currentX = 0
                currentHeight = 0
            }

            currentItems.append(FlowItem(index: index, x: currentX, size: size))
            currentX += size.width + spacing
            currentHeight = max(currentHeight, size.height)
        }

        if !currentItems.isEmpty {
            rows.append(FlowRow(y: currentY, height: currentHeight, items: currentItems))
        }
        return rows
    }

    private struct FlowRow {
        let y: CGFloat
        let height: CGFloat
        let items: [FlowItem]

        var maxY: CGFloat {
            y + height
        }
    }

    private struct FlowItem {
        let index: Int
        let x: CGFloat
        let size: CGSize
    }
}

private extension LinearIssueLoadState {
    var isBusy: Bool {
        switch self {
        case .loading, .updating:
            return true
        case .idle, .loaded, .failed:
            return false
        }
    }
}

extension Color {
    static func linearHex(_ value: String?) -> Color {
        guard let value else { return .secondary }
        let hex = value.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.count == 6, let raw = Int(hex, radix: 16) else {
            return .secondary
        }
        return Color(
            red: Double((raw >> 16) & 0xff) / 255,
            green: Double((raw >> 8) & 0xff) / 255,
            blue: Double(raw & 0xff) / 255
        )
    }
}
