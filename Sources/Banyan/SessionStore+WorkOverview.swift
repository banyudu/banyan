import BanyanCore
import Foundation

extension SessionStore {
    func workState(for id: String) -> SessionWorkState {
        if let state = workStates[id] { return state }
        let state = SessionWorkState(summary: sessionWorkSummaries[id])
        workStates[id] = state
        return state
    }

    /// Coalesce a burst of model changes into one pass. Publishing only changed
    /// rows keeps workflow progress out of the window/scene observation graph.
    func scheduleWorkSummaryUpdate() {
        guard !workStates.isEmpty, workSummaryUpdateTask == nil else { return }
        workSummaryUpdateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.workSummaryUpdateTask = nil
            let summaries = self.sessionWorkSummaries
            let ids = Set(self.sessions.map(\.id))
            for (id, state) in self.workStates {
                state.update(summaries[id])
                if !ids.contains(id) { self.workStates.removeValue(forKey: id) }
            }
        }
    }

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
            workOverview = snapshot
            if workOverviewError != nil { workOverviewError = nil }
        } catch is CancellationError { return }
        catch {
            let message = (error as? WorkitOverviewError)?.localizedDescription ?? WorkitOverviewError.unavailable.localizedDescription
            if workOverviewError != message { workOverviewError = message }
        }
    }
}
