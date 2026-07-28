import AppKit
import SwiftUI

struct GitHubIssuePanel: View {
    let context: SessionContextInfo
    let issue: GitHubIssueDetails?
    let loadState: GitHubPullRequestLoadState
    let onRefresh: () -> Void
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(issue.map { "Issue #\($0.number ?? context.githubIssueNumber ?? 0)" } ?? "GitHub Issue")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(issue?.state ?? (loadState == .loading ? "Loading" : "GitHub"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button(action: onRefresh) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.banyanBorderless)
                    .accessibilityIdentifier(AccessibilityID.githubIssueRefreshButton)
                    .help("Refresh GitHub issue")
                Button(action: onOpen) { Image(systemName: "arrow.up.forward.square") }
                    .buttonStyle(.banyanBorderless)
                    .accessibilityIdentifier(AccessibilityID.githubIssueOpenButton)
                    .help("Open in GitHub")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()
            content
        }
        .frame(width: 380)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial)
        .accessibilityIdentifier(AccessibilityID.githubIssuePanel)
    }

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .idle: Text("No GitHub issue selected").foregroundStyle(.secondary).padding(14)
        case .loading:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading GitHub issue...").foregroundStyle(.secondary) }.padding(14)
        case let .failed(message):
            VStack(alignment: .leading, spacing: 12) {
                Text(message).foregroundStyle(.secondary)
                Button("Retry", action: onRefresh).buttonStyle(.banyanBordered)
            }.padding(14)
        case .loaded:
            if let issue { issueContent(issue) } else { Text("No GitHub issue details").foregroundStyle(.secondary).padding(14) }
        }
    }

    private func issueContent(_ issue: GitHubIssueDetails) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(issue.title).font(.headline).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                HStack(spacing: 6) {
                    Text(issue.state ?? "Open").font(.caption.weight(.semibold))
                    if let author = issue.authorLogin { Text("@\(author)").foregroundStyle(.secondary) }
                }
                .font(.caption)
                if !issue.labels.isEmpty { Text(issue.labels.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                if let body = issue.body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
                    VStack(alignment: .leading, spacing: 8) { Text("Description").font(.caption.weight(.semibold)).foregroundStyle(.secondary); MarkdownText(body) }
                }
                if !issue.comments.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Recent Comments").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(issue.comments.suffix(5)) { comment in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(comment.authorLogin.map { "@\($0)" } ?? "Comment").font(.caption.weight(.semibold))
                                MarkdownText(comment.body, style: .comment).lineLimit(8)
                            }
                        }
                    }
                }
            }
            .padding(14)
        }
    }
}
