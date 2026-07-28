import SwiftUI

struct GitHubIssuePanel: View {
    let context: SessionContextInfo
    let issue: GitHubIssueDetails?
    let loadState: GitHubIssueLoadState
    let onRefresh: () -> Void
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("GitHub Issue #\(issue?.number ?? context.githubIssueNumber ?? 0)")
                        .font(.system(size: 12, weight: .semibold))
                    Text(subtitle)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button(action: onRefresh) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.banyanBorderless)
                    .accessibilityIdentifier(AccessibilityID.githubIssueRefreshButton)
                Button(action: onOpen) { Image(systemName: "arrow.up.forward.square") }
                    .buttonStyle(.banyanBorderless)
                    .accessibilityIdentifier(AccessibilityID.githubIssueOpenButton)
                    .help("Open in GitHub")
            }
            .padding(14)
            Divider()
            content
        }
        .frame(width: 380)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial)
        .accessibilityIdentifier(AccessibilityID.githubIssuePanel)
    }

    @ViewBuilder private var content: some View {
        switch loadState {
        case .idle: placeholder("No GitHub issue selected")
        case .loading: HStack { ProgressView().controlSize(.small); Text("Loading GitHub issue...").foregroundStyle(.secondary) }.padding(14)
        case let .failed(message): VStack(alignment: .leading, spacing: 12) { placeholder(message); Button("Retry", action: onRefresh).buttonStyle(.banyanBordered) }.padding(14)
        case .loaded:
            if let issue { issueContent(issue) } else { placeholder("No issue details") }
        }
    }

    private func issueContent(_ issue: GitHubIssueDetails) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(issue.title).font(.headline).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                metadata(issue)
                if let body = issue.body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
                    VStack(alignment: .leading, spacing: 8) { sectionTitle("Description"); MarkdownText(body) }
                }
                if !issue.comments.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("Recent Comments")
                        ForEach(issue.comments.suffix(5)) { comment in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(comment.authorLogin.map { "@\($0)" } ?? "Comment").font(.caption.weight(.semibold))
                                MarkdownText(comment.body, style: .comment).lineLimit(8)
                            }
                        }
                    }
                }
            }.padding(14)
        }
    }

    private func metadata(_ issue: GitHubIssueDetails) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            row("State", issue.state)
            row("Author", issue.authorLogin.map { "@\($0)" })
            row("Labels", issue.labels.isEmpty ? nil : issue.labels.joined(separator: ", "))
            row("Assignees", issue.assignees.isEmpty ? nil : issue.assignees.joined(separator: ", "))
            row("Milestone", issue.milestone)
        }.font(.caption)
    }

    @ViewBuilder private func row(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty { HStack { Text(label).foregroundStyle(.secondary).frame(width: 66, alignment: .leading); Text(value).lineLimit(2); Spacer() } }
    }
    private func sectionTitle(_ title: String) -> some View { Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase) }
    private func placeholder(_ text: String) -> some View { Text(text).foregroundStyle(.secondary).padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading) }
    private var subtitle: String { switch loadState { case .loading: "Loading"; case .failed: "Load failed"; case .loaded: issue?.state ?? "Loaded"; case .idle: context.githubIssueTitle ?? "Not loaded" } }
}
