import BanyanCore
import SwiftUI

@MainActor final class SessionWorkState: ObservableObject {
    @Published private(set) var summary: SessionWorkSummary?

    init(summary: SessionWorkSummary? = nil) { self.summary = summary }

    func update(_ summary: SessionWorkSummary?) {
        guard self.summary != summary else { return }
        self.summary = summary
    }
}

struct SessionWorkStatusButton: View {
    let summary: SessionWorkSummary
    let openSession: (String) -> Void
    @State private var isPresented = false

    private var summaryText: String {
        guard !summary.descendants.isEmpty else { return summary.own.label }
        return summary.own.needsAttention
            ? "\(summary.own.label) · \(summary.groupLabel)" : summary.groupLabel
    }

    var body: some View {
        Button { isPresented = true } label: {
            HStack(spacing: 3) {
                if summary.own.background { Image(systemName: "moon").accessibilityLabel("Background work") }
                statusContent
            }.font(.caption2)
                .foregroundStyle(summary.own.needsAttention || summary.descendants.contains(where: \.needsAttention)
                    ? Color.orange : summary.own.kind == .verified && summary.descendants.isEmpty ? Color.green : Color.secondary)
        }
        .fixedSize(horizontal: true, vertical: false)
        .buttonStyle(.banyanPlainLabelOnly)
        .help("\(summaryText) — show work details")
        .accessibilityLabel("Work details: \(summaryText)")
        .accessibilityIdentifier("session.\(summary.own.id).workflow")
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            SessionWorkDetailsView(summary: summary) { id in
                isPresented = false
                openSession(id)
            }
        }
    }

    @ViewBuilder
    private var statusContent: some View {
        if summary.descendants.isEmpty {
            Text(summary.own.label).lineLimit(1).truncationMode(.tail)
        } else {
            if summary.own.needsAttention {
                Text(summary.own.label).lineLimit(1).truncationMode(.tail)
            }
            ForEach(summary.groupStatuses) { status in
                WorkStatusBadge(status: status)
            }
        }
    }
}

private struct WorkStatusBadge: View {
    let status: SessionWorkSummary.GroupStatus

    var body: some View {
        HStack(spacing: 1) {
            Image(systemName: status.systemImage)
                .font(.system(size: 9, weight: .semibold))
            Text("\(status.count)")
                .font(.system(size: 9, weight: .semibold))
                .monospacedDigit()
        }
        .foregroundStyle(status.tint)
        .padding(.horizontal, 4)
        .frame(height: 16)
        .background(status.tint.opacity(0.12), in: Capsule())
        .help("\(status.count) \(status.label)")
        .accessibilityLabel("\(status.count) \(status.label)")
    }
}

private extension SessionWorkSummary.GroupStatus {
    var systemImage: String {
        switch category {
        case .needsYou: "hand.raised.fill"
        case .phase(let phase):
            switch phase {
            case .investigation: "magnifyingglass"
            case .implementation: "hammer.fill"
            case .prOpen: "arrow.triangle.branch"
            case .merged: "arrow.triangle.merge"
            case .verified: "checkmark.seal.fill"
            case .cancelled: "xmark.circle.fill"
            }
        case .kind(let kind):
            switch kind {
            case .working: "gearshape.fill"
            case .waiting: "clock.fill"
            case .blocked: "exclamationmark.triangle.fill"
            case .decision: "questionmark.bubble.fill"
            case .paused: "pause.circle.fill"
            case .verified: "checkmark.seal.fill"
            case .idle: "moon.zzz.fill"
            case .cancelled: "xmark.circle.fill"
            }
        }
    }

    var tint: Color {
        switch category {
        case .needsYou, .kind(.blocked), .kind(.decision): .orange
        case .phase(.verified), .kind(.verified): .green
        case .phase(.cancelled), .kind(.cancelled), .kind(.paused), .kind(.idle): .secondary
        default: .blue
        }
    }
}

struct SessionWorkDetailsView: View {
    let summary: SessionWorkSummary
    let openSession: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(summary.own.title).font(.headline).textSelection(.enabled)
                if summary.own.background {
                    Text("Working in the background. Selecting the conversation brings it back; collapsing the group does not pause its work.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if summary.own.managed || summary.own.needsAttention || summary.descendants.isEmpty { ownDetails }
                if !summary.descendants.isEmpty {
                    Text("Child sessions · \(summary.groupLabel)").font(.subheadline)
                    ForEach(summary.descendants) { entry in
                        Button { openSession(entry.id) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.title).lineLimit(2).multilineTextAlignment(.leading)
                                Text(entry.label + (entry.background ? " · Background" : ""))
                                    .font(.caption).foregroundStyle(entry.needsAttention ? .orange : .secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.borderless)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 440)
        .padding(16)
        .frame(width: 360)
    }

    @ViewBuilder private var ownDetails: some View {
        Text(summary.own.label).font(.subheadline).foregroundStyle(summary.own.needsAttention ? .orange : .secondary)
        if let job = summary.own.job {
            if let groupTitle = job.groupTitle, !groupTitle.isEmpty {
                Label(groupTitle, systemImage: "rectangle.stack").font(.caption).foregroundStyle(.secondary)
            }
            if let phase = job.phase {
                Text("Lifecycle: \(phase.label)").font(.caption).foregroundStyle(.secondary)
            }
            if let reason = job.stopReason, !reason.isEmpty {
                Text("Stopped because").font(.caption).foregroundStyle(.secondary)
                Text(reason).textSelection(.enabled)
            }
            if job.detail != job.stopReason && !job.detail.isEmpty {
                Text(job.detail).font(.callout).textSelection(.enabled)
            }
            Text("Next step").font(.caption).foregroundStyle(.secondary)
            Text(job.nextAction).textSelection(.enabled)
            Text("\(job.progress.passed)/\(job.progress.total) acceptance criteria have saved passing evidence.")
                .font(.caption).foregroundStyle(.secondary)
            if let date = job.lastProgressAt.flatMap(WorkitJobSummary.date) {
                Text("Last recorded progress \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if let url = WorkitJobSummary.webURL(job.issueURL) { Link("Issue", destination: url) }
                if let url = WorkitJobSummary.webURL(job.prURL) { Link("PR", destination: url) }
            }
            if !job.evidence.isEmpty {
                DisclosureGroup("Evidence (\(job.evidence.count))") {
                    ForEach(Array(job.evidence.enumerated()), id: \.offset) { index, value in
                        if let url = WorkitJobSummary.webURL(value) { Link("Evidence \(index + 1)", destination: url) }
                    }
                }.font(.caption)
            }
        } else {
            Text(summary.own.detail).textSelection(.enabled)
            if summary.own.managed {
                Text("Matching job details are unavailable or older than this session. Select the conversation to inspect it directly.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
