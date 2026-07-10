import AppKit
import SwiftUI

struct PullRequestPreviewPanel: View {
    let context: SessionContextInfo
    let details: GitHubPullRequestDetails?
    let loadState: GitHubPullRequestLoadState
    let onRefresh: () -> Void
    let onOpen: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            Divider()

            content
        }
        .frame(width: 380)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial)
        .accessibilityIdentifier(AccessibilityID.pullRequestPreviewPanel)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.pull")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle)
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
            .accessibilityIdentifier(AccessibilityID.pullRequestPreviewRefreshButton)
            .help("Refresh pull request")

            Button(action: onOpen) {
                Image(systemName: "arrow.up.forward.square")
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier(AccessibilityID.pullRequestPreviewOpenButton)
            .help("Open in GitHub")

            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier(AccessibilityID.pullRequestPreviewCloseButton)
            .help("Close pull request preview")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .idle:
            placeholder("No pull request selected")
        case .loading:
            loadingView("Loading pull request...")
        case let .failed(message):
            VStack(alignment: .leading, spacing: 12) {
                placeholder(message)
                Button("Retry", action: onRefresh)
                    .buttonStyle(.bordered)
            }
            .padding(14)
        case .loaded:
            if let details {
                pullRequestContent(details)
            } else {
                placeholder("No pull request details")
            }
        }
    }

    private func pullRequestContent(_ details: GitHubPullRequestDetails) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(details.title)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)

                    HStack(spacing: 6) {
                        statePill(details)
                        if let author = details.authorLogin, !author.isEmpty {
                            Text("@\(author)")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                }

                metadataGrid(details)

                if let body = details.body?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !body.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        sectionTitle("Description")
                        MarkdownText(body)
                    }
                }

                if !details.reviews.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("Reviews")
                        ForEach(details.reviews.suffix(5)) { review in
                            timelineItem(
                                title: review.authorLogin.map { "@\($0)" } ?? "Review",
                                subtitle: review.state,
                                body: review.body
                            )
                        }
                    }
                }

                if !details.comments.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("Recent Comments")
                        ForEach(details.comments.suffix(5)) { comment in
                            timelineItem(
                                title: comment.authorLogin.map { "@\($0)" } ?? "Comment",
                                subtitle: comment.createdAt,
                                body: comment.body
                            )
                        }
                    }
                }
            }
            .padding(14)
        }
    }

    private func metadataGrid(_ details: GitHubPullRequestDetails) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            metadataRow("Branch", branchSummary(details))
            metadataRow("Review", details.reviewDecision)
            metadataRow("Merge", details.mergeStateStatus ?? details.mergeable)
            metadataRow("Files", details.changedFiles.map(String.init))
            metadataRow("Diff", diffSummary(details))
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
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
        }
    }

    private func statePill(_ details: GitHubPullRequestDetails) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(stateColor(details))
                .frame(width: 7, height: 7)
            Text(stateText(details))
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.quaternary, in: Capsule())
    }

    private func timelineItem(title: String, subtitle: String?, body: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if let body = body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
                MarkdownText(body, style: .comment)
                    .lineLimit(8)
            }
        }
        .padding(.vertical, 2)
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

    private var headerTitle: String {
        if let number = details?.number ?? context.pullRequestNumber {
            return "Pull Request #\(number)"
        }
        return "Pull Request"
    }

    private var headerSubtitle: String {
        switch loadState {
        case .idle:
            return context.pullRequestTitle ?? "Not loaded"
        case .loading:
            return "Loading"
        case .loaded:
            return details.map(stateText) ?? "Loaded"
        case .failed:
            return "Load failed"
        }
    }

    private func stateText(_ details: GitHubPullRequestDetails) -> String {
        if details.isDraft {
            return "Draft"
        }
        return details.state ?? "Open"
    }

    private func stateColor(_ details: GitHubPullRequestDetails) -> Color {
        if details.isDraft {
            return .secondary
        }
        switch details.state?.lowercased() {
        case "open":
            return .green
        case "merged":
            return .purple
        case "closed":
            return .red
        default:
            return .secondary
        }
    }

    private func branchSummary(_ details: GitHubPullRequestDetails) -> String? {
        guard let head = details.headRefName, !head.isEmpty else {
            return details.baseRefName
        }
        guard let base = details.baseRefName, !base.isEmpty else {
            return head
        }
        return "\(head) -> \(base)"
    }

    private func diffSummary(_ details: GitHubPullRequestDetails) -> String? {
        guard details.additions != nil || details.deletions != nil else {
            return nil
        }
        return "+\(details.additions ?? 0) -\(details.deletions ?? 0)"
    }
}
