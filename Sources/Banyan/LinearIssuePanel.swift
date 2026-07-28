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
            return 860
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
    let onToggleTask: (Int) -> Void
    let onRetryDescription: () -> Void
    let onStart: (() -> Void)?
    let isStarting: Bool
    let presentation: LinearIssuePanelPresentation
    @State private var selectedStateID: String?

    init(
        context: SessionContextInfo,
        issue: LinearIssueDetails?,
        loadState: LinearIssueLoadState,
        onRefresh: @escaping () -> Void,
        onOpen: @escaping () -> Void,
        onChangeState: @escaping (LinearWorkflowState) -> Void,
        onToggleTask: @escaping (Int) -> Void = { _ in },
        onRetryDescription: @escaping () -> Void = {},
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
        self.onToggleTask = onToggleTask
        self.onRetryDescription = onRetryDescription
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
        case .updatingDescription:
            if let issue { issueContent(issue, statusMessage: "Saving description…") }
            else { loadingView("Saving description…") }
        case let .failed(message):
            if let issue {
                VStack(alignment: .leading, spacing: 10) {
                    errorBanner(message)
                    issueContent(issue)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    placeholder(message)
                    Button("Retry", action: onRefresh)
                        .buttonStyle(.banyanBordered)
                }
                .padding(14)
            }
        case .loaded:
            if let issue {
                issueContent(issue)
            } else {
                placeholder("No issue details")
            }
        }
    }

    private func issueContent(_ issue: LinearIssueDetails, statusMessage: String? = nil) -> some View {
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
                        MarkdownText(description, onToggleTask: onToggleTask)
                            .disabled(loadState.isBusy)
                        if let statusMessage {
                            savingLabel(statusMessage)
                        }
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
                            .buttonStyle(.banyanPlain)
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
                                MarkdownText(comment.body, style: .comment)
                                    .lineLimit(8)
                            }
                            .padding(.vertical, 2)
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

    private func savingLabel(_ message: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(message)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message)
            Spacer(minLength: 4)
            Button("Retry", action: onRetryDescription)
                .buttonStyle(.banyanBordered)
                .controlSize(.small)
        }
        .font(.caption)
        .foregroundStyle(.red)
        .padding(.horizontal, 14)
        .padding(.top, 10)
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
        case .updatingDescription:
            return "Saving"
        case .loaded:
            return issue?.state.name ?? "Loaded"
        case .failed:
            return "Needs Linear auth"
        }
    }
}
