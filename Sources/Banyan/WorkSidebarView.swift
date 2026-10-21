import AppKit
import BanyanCore
import SwiftUI

@MainActor
final class WorkSidebarModel: ObservableObject {
    @Published private(set) var snapshot: WorkitOverview?
    @Published private(set) var isRefreshing = false
    @Published private(set) var error: String?
    private let client: any WorkitOverviewClient

    init(client: any WorkitOverviewClient) { self.client = client }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let value = try await client.fetch()
            try Task.checkCancellation()
            snapshot = value; error = nil
        } catch is CancellationError { return }
        catch { self.error = (error as? WorkitOverviewError)?.localizedDescription ?? WorkitOverviewError.unavailable.localizedDescription }
    }
}

struct WorkSidebarView: View {
    @StateObject private var model: WorkSidebarModel
    let sessionIDs: Set<String>
    let openSession: (String) -> Void

    init(client: any WorkitOverviewClient, sessionIDs: Set<String>, openSession: @escaping (String) -> Void) {
        _model = StateObject(wrappedValue: WorkSidebarModel(client: client))
        self.sessionIDs = sessionIDs; self.openSession = openSession
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Work").font(.headline)
                if let snapshot = model.snapshot { Text("\(snapshot.total)").foregroundStyle(.secondary) }
                Spacer()
                if model.isRefreshing { ProgressView().controlSize(.small) }
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(model.isRefreshing).help("Refresh work").accessibilityLabel("Refresh work")
            }.padding(12)
            if let error = model.error {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.snapshot == nil ? "Work unavailable" : "Showing saved results").font(.headline)
                    Text(error).font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            if let snapshot = model.snapshot {
                WorkJobList(snapshot: snapshot, sessionIDs: sessionIDs, openSession: openSession)
                if snapshot.truncated {
                    Text("Showing \(snapshot.jobs.count) of \(snapshot.total) jobs. Use workit job list for the full history.")
                        .font(.caption).foregroundStyle(.secondary).padding(8)
                }
                if let date = WorkitJobSummary.date(snapshot.generatedAt) {
                    Text("Refreshed \(date.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary).padding(8)
                }
            } else { Spacer() }
        }
        .task { await model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refresh() }
        }
    }
}

struct WorkJobList: View {
    let snapshot: WorkitOverview
    let sessionIDs: Set<String>
    let openSession: (String) -> Void

    var body: some View {
        if snapshot.jobs.isEmpty {
            ContentUnavailableView("No managed work", systemImage: "checklist", description: Text("Jobs launched with workit appear here, including work whose conversation is closed."))
        } else {
            List {
                ForEach(WorkitJobSummary.Group.allCases, id: \.self) { group in
                    let jobs = snapshot.jobs.filter { $0.group == group }
                    if !jobs.isEmpty {
                        Section("\(group.label) · \(jobs.count)") {
                            ForEach(jobs) { job in
                                WorkJobRow(job: job, canOpen: job.sessionID.map(sessionIDs.contains) ?? false) {
                                    if let id = job.sessionID { openSession(id) }
                                }
                            }
                        }
                    }
                }
            }.listStyle(.sidebar)
        }
    }
}

struct WorkJobRow: View {
    let job: WorkitJobSummary
    let canOpen: Bool
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(job.title).font(.headline).fixedSize(horizontal: false, vertical: true)
            Text("\(job.stage.replacingOccurrences(of: "-", with: " ").capitalized) · \(job.progress.passed)/\(job.progress.total) ACs proven")
                .font(.caption).foregroundStyle(.secondary)
            if !job.detail.isEmpty { Text(job.detail).font(.callout).lineLimit(3).help(job.detail) }
            Text(job.nextAction).font(.caption).fixedSize(horizontal: false, vertical: true)
            if let date = WorkitJobSummary.date(job.lastProgressAt) {
                Text("Progress \(date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("Progress time unavailable").font(.caption2).foregroundStyle(.secondary)
            }
            if let date = WorkitJobSummary.date(job.nextWakeAt) {
                Text("Next check \(date.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                if let url = WorkitJobSummary.webURL(job.issueURL) { Link("Issue", destination: url) }
                if let url = WorkitJobSummary.webURL(job.prURL) { Link("PR", destination: url) }
                if canOpen { Button("Conversation", action: open).buttonStyle(.link) }
            }.font(.caption)
            if !canOpen { Text("Conversation unavailable").font(.caption2).foregroundStyle(.secondary) }
            ForEach(Array(job.evidence.enumerated()), id: \.offset) { index, reference in
                if let url = WorkitJobSummary.webURL(reference) { Link("Evidence \(index + 1)", destination: url).font(.caption) }
            }
        }.padding(.vertical, 6).textSelection(.enabled)
    }
}
