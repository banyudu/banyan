import BanyanCore
import Foundation

extension SessionStore {
    func workNode(for session: BanyanSession, background: Bool = false) -> SessionWorkNode {
        SessionWorkNode(id: session.id, parentID: session.parentSessionID, title: session.displayTitle,
            status: session.status, workflow: session.workflow, background: background,
            recoveryError: session.workflowRecoveryError != nil)
    }

    var sessionWorkSummaries: [String: SessionWorkSummary] {
        if cachedWorkSummaryRevision != workSummaryRevision || cachedWorkSidebarRevision != sidebarGroupsRevision
            || cachedWorkOverviewTime != workOverview?.generatedAt {
            let background = backgroundedSessionIDs
            cachedWorkSummaries = SessionWorkTree.summaries(nodes: sessions.filter { !$0.isImportedHistory && $0.status != .closed }
                .map { workNode(for: $0, background: background.contains($0.id)) }, overview: workOverview)
            cachedWorkSummaryRevision = workSummaryRevision; cachedWorkSidebarRevision = sidebarGroupsRevision
            cachedWorkOverviewTime = workOverview?.generatedAt
        }
        return cachedWorkSummaries
    }

    /// Workflow projections arrive in bursts. Coalesce them without polling or a
    /// process per row. Fetch also occurs on app activation and explicit refresh.
    func scheduleWorkOverviewRefresh() {
        guard !isRefreshingWorkOverview else { workOverviewRefreshRequested = true; return }
        workOverviewRefreshTask?.cancel()
        workOverviewRefreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard let self else { return }
            await self.refreshWorkOverview()
        }
    }

    func refreshWorkOverview() async {
        guard !isRefreshingWorkOverview else { workOverviewRefreshRequested = true; return }
        isRefreshingWorkOverview = true
        defer {
            isRefreshingWorkOverview = false
            if workOverviewRefreshRequested {
                workOverviewRefreshRequested = false
                scheduleWorkOverviewRefresh()
            }
        }
        do {
            let snapshot = try await WorkitCommandOverviewClient(host: host).fetch()
            try Task.checkCancellation()
            workOverview = snapshot; workOverviewError = nil
        } catch is CancellationError { return }
        catch { workOverviewError = (error as? WorkitOverviewError)?.localizedDescription ?? WorkitOverviewError.unavailable.localizedDescription }
    }
}
