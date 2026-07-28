import AppKit
import SwiftUI

enum LinearIssuePanelPresentation {
    case sidebar
    case main

    var width: CGFloat? {
        switch self {
        case .sidebar:
            return 360
        case .main:
            return nil
        }
    }

    var maxWidth: CGFloat? {
        switch self {
        case .sidebar:
            return nil
        case .main:
            return .infinity
        }
    }

    var contentMaxWidth: CGFloat? {
        switch self {
        case .sidebar:
            return nil
        case .main:
            return 920
        }
    }
}

struct LinearIssuePanel: View {
    let context: SessionContextInfo
    let issue: LinearIssueDetails?
    let loadState: LinearIssueLoadState
    let onRefresh: () -> Void
    let onOpen: () -> Void
    let onChangeState: (LinearWorkflowState) -> Void
    let onStart: (() -> Void)?
    let isStarting: Bool
    let presentation: LinearIssuePanelPresentation
    @State private var selectedStateID: String?
    @State private var expandedCommentIDs: Set<String> = []

    init(
        context: SessionContextInfo,
        issue: LinearIssueDetails?,
        loadState: LinearIssueLoadState,
        onRefresh: @escaping () -> Void,
        onOpen: @escaping () -> Void,
        onChangeState: @escaping (LinearWorkflowState) -> Void,
        onStart: (() -> Void)? = nil,
        isStarting: Bool = false,
        presentation: LinearIssuePanelPresentation = .sidebar
    ) {
        self.context = context
        self.issue = issue
        self.loadState = loadState
        self.onRefresh = onRefresh
        self.onOpen = onOpen
        self.onChangeState = onChangeState
        self.onStart = onStart
        self.isStarting = isStarting
        self.presentation = presentation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            Divider()

            content
        }
        .frame(width: presentation.width)
        .frame(maxWidth: presentation.maxWidth, maxHeight: .infinity, alignment: .topLeading)
        .background(panelBackground)
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

            if let onStart {
                startButton(onStart)
            }

            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.banyanBorderless)
            .accessibilityIdentifier(AccessibilityID.linearIssueRefreshButton)
            .help("Refresh Linear issue")

            Button(action: onOpen) {
                Image(systemName: "arrow.up.forward.square")
            }
            .buttonStyle(.banyanBorderless)
            .accessibilityIdentifier(AccessibilityID.linearIssueOpenButton)
            .help("Open in Linear")
        }
    }

    @ViewBuilder
    private var panelBackground: some View {
        switch presentation {
        case .sidebar:
            Rectangle()
                .fill(.regularMaterial)
        case .main:
            Color.clear
        }
    }

    @ViewBuilder
    private func startButton(_ action: @escaping () -> Void) -> some View {
        switch presentation {
        case .sidebar:
            Button(action: action) {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.banyanBorderless)
            .disabled(isStarting)
            .help("Start Banyan session")
        case .main:
            Button(action: action) {
                Label("Start Session", systemImage: "play.fill")
            }
            .buttonStyle(.banyanBorderedProminent)
            .controlSize(.small)
            .disabled(isStarting)
            .help("Start Banyan session")
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
                    .buttonStyle(.banyanBordered)
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
            VStack(alignment: .leading, spacing: 24) {
                issueHero(issue)

                metadataGrid(issue)

                if let description = issue.description?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !description.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("Description")
                        MarkdownText(description)
                    }
                }

                if !issue.labels.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
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
                    VStack(alignment: .leading, spacing: 10) {
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
                            .buttonStyle(.banyanPlain)
                            .foregroundStyle(.primary)
                        }
                    }
                }

                if !issue.comments.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        sectionTitle("Recent Comments")
                        ForEach(issue.comments) { comment in
                            commentView(comment)
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: presentation.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            selectedStateID = issue.state.id
        }
        .onChange(of: issue.state.id) { _, newValue in
            selectedStateID = newValue
        }
    }

    private func issueHero(_ issue: LinearIssueDetails) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Text(issue.identifier)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                Spacer(minLength: 8)

                if !issue.workflowStates.isEmpty {
                    statusControl(issue)
                }
            }

            Text(issue.title)
                .font(presentation == .main ? .title2.weight(.semibold) : .title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private func statusControl(_ issue: LinearIssueDetails) -> some View {
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
        .pickerStyle(.menu)
        .controlSize(.small)
        .disabled(loadState.isBusy)
        .help("Change Linear status")
        .accessibilityIdentifier(AccessibilityID.linearIssueStatusPicker)
    }

    private func commentView(_ comment: LinearIssueComment) -> some View {
        let isExpanded = expandedCommentIDs.contains(comment.id)
        let isLong = comment.body.count > 420 || comment.body.split(separator: "\n").count > 8

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(comment.userName ?? "Unknown")
                    .font(.caption.weight(.semibold))
                if let timestamp = comment.relativeTimestamp {
                    Text(timestamp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            if isLong {
                DisclosureGroup(isExpanded: commentExpansionBinding(for: comment.id)) {
                    MarkdownText(comment.body, style: .comment)
                        .padding(.top, 4)
                } label: {
                    MarkdownText(comment.body, style: .comment)
                        .frame(maxHeight: isExpanded ? nil : 112, alignment: .top)
                        .clipped()
                        .overlay(alignment: .bottom) {
                            if !isExpanded {
                                LinearGradient(
                                    colors: [.clear, Color(nsColor: .windowBackgroundColor)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                                .frame(height: 28)
                                .allowsHitTesting(false)
                            }
                        }
                }
            } else {
                MarkdownText(comment.body, style: .comment)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func commentExpansionBinding(for id: String) -> Binding<Bool> {
        Binding {
            expandedCommentIDs.contains(id)
        } set: { isExpanded in
            if isExpanded {
                expandedCommentIDs.insert(id)
            } else {
                expandedCommentIDs.remove(id)
            }
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

private extension LinearIssueComment {
    var relativeTimestamp: String? {
        guard let createdAt,
              let date = ISO8601DateFormatter().date(from: createdAt) else {
            return nil
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
