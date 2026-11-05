import BanyanCore
import Foundation
import AppKit
import SwiftUI

extension SessionStore {
    /// Shows the cached list immediately, then refreshes it in the background
    /// whenever the Linear tab becomes visible.
    func refreshLinearIssueListOnEnter() {
        refreshLinearIssueList()
    }

    func refreshLinearIssueListIfNeeded() {
        loadCachedLinearIssuesIfNeeded()
        guard linearIssueListTask == nil else { return }
        switch linearIssueListLoadState {
        case .idle, .loaded, .failed:
            refreshLinearIssueList()
        case .loading, .starting:
            break
        }
    }

    func refreshLinearIssueList() {
        loadCachedLinearIssuesIfNeeded()
        guard linearIssueListTask == nil else {
            linearDebugLog("list refresh ignored because refresh is already running", environment: self.environment, homeDirectory: self.homeDirectory)
            return
        }
        let hasStaleIssues = !linearIssues.isEmpty
        linearIssueListLoadState = hasStaleIssues ? .loaded : .loading
        isLinearIssueListRefreshing = true
        let cwd = selectedSession?.cwd ?? homeDirectory
        let deadline = Date().addingTimeInterval(Self.linearIssueListLoadTimeout)
        let requestID = UUID()
        linearIssueListRequestID = requestID
        linearDebugLog("list refresh start cwd=\(cwd) staleCount=\(linearIssues.count) staleStates=[\(linearIssueStateCountSummary(linearIssues))]", environment: self.environment, homeDirectory: self.homeDirectory)
        let environment = self.environment
        let homeDirectory = self.homeDirectory
        linearIssueListTask = Task.detached(priority: .utility) { [environment, homeDirectory] in
            do {
                async let issuesRequest = LinearIssueClient.fetchIssueList(cwd: cwd, deadline: deadline, environment: environment, homeDirectory: homeDirectory)
                async let workflowStatesRequest = LinearIssueClient.fetchWorkflowStates(cwd: cwd, deadline: deadline, environment: environment, homeDirectory: homeDirectory)
                let issues = try await issuesRequest
                let workflowStates: [LinearWorkflowState]?
                do {
                    workflowStates = try await workflowStatesRequest
                } catch {
                    linearDebugLog("workflow states refresh failed error=\(error.localizedDescription)", environment: environment, homeDirectory: homeDirectory)
                    workflowStates = nil
                }
                await MainActor.run { [weak self] in
                    guard let self, self.linearIssueListRequestID == requestID else { return }
                    self.linearIssueListWatchdogTask?.cancel()
                    self.linearIssueListWatchdogTask = nil
                    self.linearIssueListTask = nil
                    self.isLinearIssueListRefreshing = false
                    self.linearIssues = issues
                    let workflowStateSource = workflowStates ?? self.linearIssueWorkflowStates
                    self.linearIssueWorkflowStates = LinearIssuePolicy.mergedWorkflowStates(workflowStateSource, issues: issues)
                    linearDebugLog("list refresh applied issueCount=\(issues.count) issueStates=[\(linearIssueStateCountSummary(issues))] workflowStateCount=\(self.linearIssueWorkflowStates.count) workflowStates=[\(linearWorkflowStateSummary(self.linearIssueWorkflowStates))]", environment: environment, homeDirectory: homeDirectory)
                    if let selectedLinearListIssueID = self.selectedLinearListIssueID,
                       !issues.contains(where: { $0.identifier == selectedLinearListIssueID }) {
                        self.selectedLinearListIssueID = issues.first?.identifier
                    } else if self.selectedLinearListIssueID == nil {
                        self.selectedLinearListIssueID = issues.first?.identifier
                    }
                    self.persistLinearIssueListCache(
                        LinearIssueListCacheSnapshot(
                            issues: issues,
                            workflowStates: self.linearIssueWorkflowStates,
                            selectedIssueID: self.selectedLinearListIssueID,
                            updatedAt: Date()
                        )
                    )
                    self.linearIssueListLoadState = .loaded
                }
            } catch {
                linearDebugLog("list refresh failed error=\(error.localizedDescription)", environment: environment, homeDirectory: homeDirectory)
                await MainActor.run { [weak self] in
                    guard let self, self.linearIssueListRequestID == requestID else { return }
                    self.linearIssueListWatchdogTask?.cancel()
                    self.linearIssueListWatchdogTask = nil
                    self.linearIssueListTask = nil
                    self.isLinearIssueListRefreshing = false
                    let timedOut: Bool
                    if let clientError = error as? LinearIssueClientError,
                       case .requestTimedOut = clientError {
                        timedOut = true
                    } else {
                        timedOut = false
                    }
                    self.linearIssueListLoadState = .failed(
                        timedOut
                            ? "Linear refresh timed out. Click refresh to try again."
                            : "Unable to refresh Linear issues. Click refresh to try again."
                    )
                }
            }
        }
        // A subprocess can wedge without returning through its async bridge.
        // Do not let that permanently suppress every future refresh; a late
        // completion is ignored by the request-generation check above.
        linearIssueListWatchdogTask?.cancel()
        linearIssueListWatchdogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard !Task.isCancelled else { return }
            guard let self, self.linearIssueListRequestID == requestID else { return }
            self.linearIssueListRequestID = UUID()
            self.linearIssueListTask?.cancel()
            self.linearIssueListTask = nil
            self.isLinearIssueListRefreshing = false
            self.linearIssueListLoadState = .failed("Linear refresh timed out. Click refresh to try again.")
            linearDebugLog("list refresh watchdog expired", environment: self.environment, homeDirectory: self.homeDirectory)
        }
    }

    /// The Linear list is also refreshed while the user is working elsewhere in
    /// Banyan. This timer only starts the existing detached network task, so it
    /// does not block the main actor or replace the stale list while loading.
    func installLinearIssueListRefreshTimer() {
        let interval = Self.linearIssueListRefreshInterval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshLinearIssueList()
            }
        }
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        linearIssueListRefreshTimer = timer
    }

    private func loadCachedLinearIssuesIfNeeded() {
        guard !didLoadCachedLinearIssues else { return }
        didLoadCachedLinearIssues = true
        guard linearIssues.isEmpty,
              let cache = persistence.loadLinearIssueListCache(),
              !cache.issues.isEmpty else {
            return
        }

        linearIssues = cache.issues
        linearIssueWorkflowStates = LinearIssuePolicy.mergedWorkflowStates(cache.workflowStates ?? [], issues: cache.issues)
        linearDebugLog("list cache loaded issueCount=\(cache.issues.count) issueStates=[\(linearIssueStateCountSummary(cache.issues))] workflowStateCount=\(linearIssueWorkflowStates.count) selectedIssueID=\(cache.selectedIssueID ?? "nil") updatedAt=\(cache.updatedAt)", environment: self.environment, homeDirectory: self.homeDirectory)
        let cachedIssueIDs = Set(cache.issues.map(\.identifier))
        if let selectedLinearListIssueID, cachedIssueIDs.contains(selectedLinearListIssueID) {
            linearIssueListLoadState = .loaded
            return
        }
        if let selectedIssueID = cache.selectedIssueID,
           cachedIssueIDs.contains(selectedIssueID) {
            selectedLinearListIssueID = selectedIssueID
        } else {
            selectedLinearListIssueID = cache.issues.first?.identifier
        }
        linearIssueListLoadState = .loaded
    }

    func mergeLinearWorkflowStates(_ workflowStates: [LinearWorkflowState]) {
        guard !workflowStates.isEmpty else { return }
        let mergedWorkflowStates = LinearIssuePolicy.mergedWorkflowStates(
            linearIssueWorkflowStates + workflowStates,
            issues: linearIssues
        )
        guard mergedWorkflowStates != linearIssueWorkflowStates else { return }
        linearIssueWorkflowStates = mergedWorkflowStates
        guard !linearIssues.isEmpty else { return }
        persistLinearIssueListCache(
            LinearIssueListCacheSnapshot(
                issues: linearIssues,
                workflowStates: linearIssueWorkflowStates,
                selectedIssueID: selectedLinearListIssueID,
                updatedAt: Date()
            )
        )
    }

    func refreshSelectedLinearListIssue(force: Bool = false) {
        guard let issueID = selectedLinearListIssueID else {
            selectedLinearListIssueTask?.cancel()
            selectedLinearListIssueTask = nil
            selectedLinearListIssueDetails = nil
            selectedLinearListIssueLoadState = .idle
            return
        }

        guard force || selectedLinearListIssueDetails?.identifier != issueID else { return }

        selectedLinearListIssueTask?.cancel()
        let cachedDetails = linearIssueDetailsCache[issueID]
        let hasStaleDetails = cachedDetails != nil
            || selectedLinearListIssueDetails?.identifier == issueID
        selectedLinearListIssueLoadState = hasStaleDetails ? .loaded : .loading
        if let cachedDetails {
            selectedLinearListIssueDetails = cachedDetails
        } else if !hasStaleDetails {
            selectedLinearListIssueDetails = nil
        }

        let cwd = selectedSession?.cwd ?? homeDirectory
        let environment = self.environment
        let homeDirectory = self.homeDirectory
        selectedLinearListIssueTask = Task.detached(priority: .utility) { [environment, homeDirectory] in
            do {
                let issue = try await LinearIssueClient.fetchIssue(identifier: issueID, cwd: cwd, environment: environment, homeDirectory: homeDirectory)
                await MainActor.run { [weak self] in
                    guard let self, self.selectedLinearListIssueID == issueID else { return }
                    self.selectedLinearListIssueTask = nil
                    self.linearIssueDetailsCache[issueID] = issue
                    self.selectedLinearListIssueDetails = issue
                    self.mergeLinearWorkflowStates(issue.workflowStates)
                    self.selectedLinearListIssueLoadState = .loaded
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.selectedLinearListIssueID == issueID else { return }
                    self.selectedLinearListIssueTask = nil
                    self.selectedLinearListIssueLoadState =
                        self.linearIssueDetailsCache[issueID] != nil
                        || self.selectedLinearListIssueDetails?.identifier == issueID
                        ? .loaded
                        : .failed(LinearIssueClient.message(for: error))
                }
            }
        }
    }

    func openSelectedLinearListIssue() {
        guard let url = selectedLinearListIssueURL else { return }
        NSWorkspace.shared.open(url)
    }

    func requestLinearFilterFocus() {
        linearFilterFocusRequestID = UUID()
    }

    func updateLinearIssueNavigationIDs(_ ids: [String]) {
        guard linearIssueNavigationIDs != ids else { return }
        linearIssueNavigationIDs = ids
        if let selectedLinearListIssueID,
           ids.contains(selectedLinearListIssueID) {
            return
        }
        selectedLinearListIssueID = ids.first
    }

    func updateSelectedLinearListIssueState(_ state: LinearWorkflowState) {
        guard let issueID = selectedLinearListIssueID else { return }
        selectedLinearListIssueTask?.cancel()
        selectedLinearListIssueLoadState = .updating(state.name)

        let cwd = selectedSession?.cwd ?? homeDirectory
        let environment = self.environment
        let homeDirectory = self.homeDirectory
        selectedLinearListIssueTask = Task.detached(priority: .userInitiated) { [environment, homeDirectory] in
            do {
                try await LinearIssueClient.updateIssueState(identifier: issueID, state: state, cwd: cwd, environment: environment, homeDirectory: homeDirectory)
                let issue = try await LinearIssueClient.fetchIssue(identifier: issueID, cwd: cwd, environment: environment, homeDirectory: homeDirectory)
                await MainActor.run { [weak self] in
                    guard let self, self.selectedLinearListIssueID == issueID else { return }
                    self.selectedLinearListIssueTask = nil
                    self.linearIssueDetailsCache[issueID] = issue
                    self.selectedLinearListIssueDetails = issue
                    self.mergeLinearWorkflowStates(issue.workflowStates)
                    self.selectedLinearListIssueLoadState = .loaded
                    self.refreshLinearIssueList()
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.selectedLinearListIssueID == issueID else { return }
                    self.selectedLinearListIssueTask = nil
                    self.selectedLinearListIssueLoadState = .failed(LinearIssueClient.message(for: error, action: "update"))
                }
            }
        }
    }

    func startSelectedLinearListIssueSession() {
        guard let issueID = selectedLinearListIssueID else { return }
        startLinearIssueSession(issueID)
    }

    func startLinearIssueSession(_ issueID: String) {
        linearIssueListLoadState = .starting(issueID)
        let cwd = selectedSession?.cwd ?? homeDirectory
        let environment = self.environment
        let homeDirectory = self.homeDirectory
        Task.detached(priority: .userInitiated) { [environment, homeDirectory] in
            let errorMessage = Self.runBanyanWorktree(
                issueID: issueID,
                cwd: cwd,
                homeDirectory: homeDirectory,
                environment: environment
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                if let errorMessage {
                    self.linearIssueListLoadState = .failed(errorMessage)
                } else {
                    self.sidebarMode = .sessions
                    self.linearIssueListLoadState = .loaded
                    self.runHistoryImport()
                }
            }
        }
    }
}
