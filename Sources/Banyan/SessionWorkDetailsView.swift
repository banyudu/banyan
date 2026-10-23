import AppKit
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

/// Refresh metadata belongs to the open details popup, not every sidebar row.
@MainActor final class WorkOverviewStatus: ObservableObject {
    @Published var error: String?
    @Published var updatedAt: String?
}

struct SessionWorkStatusButton: View {
    let summary: SessionWorkSummary
    let overviewStatus: WorkOverviewStatus
    let refresh: () -> Void
    let openSession: (String) -> Void
    @State private var isPresented = false

    private var label: String {
        if summary.descendants.isEmpty { return summary.own.label }
        return summary.own.needsAttention
            ? "\(summary.own.label) · \(summary.groupLabel)" : summary.groupLabel
    }
    var body: some View {
        Button { isPresented = true } label: {
            HStack(spacing: 3) {
                if summary.own.background { Image(systemName: "moon").accessibilityLabel("Background work") }
                Text(label).lineLimit(1).truncationMode(.tail)
            }.font(.caption2)
                .foregroundStyle(summary.own.needsAttention || summary.descendants.contains(where: \.needsAttention)
                    ? Color.orange : summary.own.kind == .verified && summary.descendants.isEmpty ? Color.green : Color.secondary)
                .frame(maxWidth: summary.descendants.isEmpty ? 85 : 110, alignment: .trailing)
        }
        .fixedSize(horizontal: true, vertical: false)
        .buttonStyle(.banyanPlainLabelOnly)
        .help("\(label) — show work details")
        .accessibilityLabel("Work details: \(label)")
        .accessibilityIdentifier("session.\(summary.own.id).workflow")
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            LiveSessionWorkDetailsView(summary: summary, status: overviewStatus, refresh: refresh) { id in
                isPresented = false
                openSession(id)
            }
        }
    }
}

private struct LiveSessionWorkDetailsView: View {
    let summary: SessionWorkSummary
    @ObservedObject var status: WorkOverviewStatus
    let refresh: () -> Void
    let openSession: (String) -> Void

    var body: some View {
        SessionWorkDetailsView(summary: summary, error: status.error, updatedAt: status.updatedAt,
            refresh: refresh, openSession: openSession)
    }
}

struct SessionWorkDetailsView: View {
    let summary: SessionWorkSummary
    let error: String?
    let updatedAt: String?
    let refresh: () -> Void
    let openSession: (String) -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Work details").font(.headline)
                Spacer()
                Button(action: refresh) { Image(systemName: "arrow.clockwise") }.help("Refresh saved work status")
                    .accessibilityLabel("Refresh work details")
            }
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
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 440)
            Divider()
            if let error, summary.own.managed || summary.descendants.contains(where: \.managed) {
                Text("Saved details may be out of date. \(error)").font(.caption).foregroundStyle(.secondary)
            } else if let date = updatedAt.flatMap(WorkitJobSummary.date) {
                Text("Status loaded \(date.formatted(date: .omitted, time: .shortened)). Refresh reads saved status; it does not resume work.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Open conversation") { openSession(summary.own.id) }
                if let job = summary.own.job, summary.own.needsAttention {
                    Button(copied ? "Copied" : "Copy inspection request") {
                        let request = "Inspect workit job \(job.id) in its original conversation. Saved reason: \(job.stopReason ?? job.detail). Next step: \(job.nextAction). Check current state and any uncertain continuation receipts before proposing recovery."
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(request, forType: .string)
                        copied = true
                    }.help("Copy a request to paste into the conversation; no prompt is sent automatically")
                }
            }
        }.padding(16).frame(width: 360)
    }

    @ViewBuilder private var ownDetails: some View {
        Text(summary.own.label).font(.subheadline).foregroundStyle(summary.own.needsAttention ? .orange : .secondary)
        if let job = summary.own.job {
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
                Text("Matching job details are unavailable or older than this session. Refresh, or inspect the original conversation.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
