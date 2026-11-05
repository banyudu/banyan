import BanyanCore
import Foundation
import AppKit
import SwiftUI

extension SessionStore {
    func openSelectedLinearIssue() {
        if sidebarMode == .linear {
            openSelectedLinearListIssue()
            return
        }
        guard let url = selectedLinearIssueURL else { return }
        NSWorkspace.shared.open(url)
    }

    func openSelectedGitHubIssue() {
        if let value = selectedContextInfo?.githubIssueURL, let url = URL(string: value) {
            NSWorkspace.shared.open(url)
        }
    }

    func refreshSelectedGitHubIssue(force: Bool = false) {
        guard let session = selectedSession, session.status != .closed,
              let value = selectedContextInfo?.githubIssueURL, let url = URL(string: value) else {
            selectedGitHubIssueTask?.cancel()
            selectedGitHubIssueTask = nil
            selectedGitHubIssueURL = nil
            selectedGitHubIssueDetails = nil
            selectedGitHubIssueLoadState = .idle
            return
        }
        guard force || selectedGitHubIssueURL != url || selectedGitHubIssueDetails == nil else { return }
        selectedGitHubIssueTask?.cancel()
        selectedGitHubIssueURL = url
        selectedGitHubIssueDetails = nil
        selectedGitHubIssueLoadState = .loading
        let sessionID = session.id
        let cwd = session.cwd
        let environment = self.environment
        let homeDirectory = self.homeDirectory
        selectedGitHubIssueTask = Task.detached(priority: .utility) { [environment, homeDirectory] in
            do {
                let details = try await GitHubIssueClient.fetchIssue(
                    url: url,
                    cwd: cwd,
                    environment: environment,
                    homeDirectory: homeDirectory
                )
                await MainActor.run { [weak self] in
                    guard let self, self.selectedSessionID == sessionID,
                          self.selectedContextInfo?.githubIssueURL == url.absoluteString,
                          self.selectedGitHubIssueURL == url else { return }
                    self.selectedGitHubIssueTask = nil
                    self.selectedGitHubIssueDetails = details
                    self.selectedGitHubIssueLoadState = .loaded
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.selectedSessionID == sessionID,
                          self.selectedGitHubIssueURL == url else { return }
                    self.selectedGitHubIssueTask = nil
                    self.selectedGitHubIssueLoadState = .failed(GitHubIssueClient.message(for: error))
                }
            }
        }
    }

    func refreshSelectedLinearIssue(force: Bool = false) {
        guard let session = selectedSession,
              session.status != .closed,
              let context = selectedContextInfo,
              let issueID = context.linearIssueID,
              !issueID.isEmpty else {
            selectedLinearIssueTask?.cancel()
            selectedLinearIssueTask = nil
            selectedLinearIssueStatusTask?.cancel()
            selectedLinearIssueStatusTask = nil
            stopSelectedLinearIssueStatusRefresh()
            selectedLinearIssueIdentifier = nil
            if selectedLinearIssueDetails != nil { selectedLinearIssueDetails = nil }
            if selectedLinearIssueLoadState != .idle { selectedLinearIssueLoadState = .idle }
            return
        }

        guard force
            || selectedLinearIssueIdentifier != issueID
            || selectedLinearIssueDetails?.identifier != issueID else {
            startSelectedLinearIssueStatusRefreshIfNeeded()
            return
        }

        selectedLinearIssueTask?.cancel()
        selectedLinearIssueStatusTask?.cancel()
        selectedLinearIssueStatusTask = nil
        selectedLinearIssueStatusRetryAfter = .distantPast
        selectedLinearIssueIdentifier = issueID
        let cachedDetails = linearIssueDetailsCache[issueID]
        let hasStaleDetails = cachedDetails != nil
            || selectedLinearIssueDetails?.identifier == issueID
        if let cachedDetails {
            if selectedLinearIssueDetails != cachedDetails { selectedLinearIssueDetails = cachedDetails }
        } else if !hasStaleDetails {
            if selectedLinearIssueDetails != nil { selectedLinearIssueDetails = nil }
        }
        let loadState: LinearIssueLoadState = hasStaleDetails ? .loaded : .loading
        if selectedLinearIssueLoadState != loadState { selectedLinearIssueLoadState = loadState }

        let cwd = session.cwd
        let sessionID = session.id
        let environment = self.environment
        let homeDirectory = self.homeDirectory
        selectedLinearIssueTask = Task.detached(priority: .utility) { [environment, homeDirectory] in
            do {
                let issue = try await LinearIssueClient.fetchIssue(identifier: issueID, cwd: cwd, environment: environment, homeDirectory: homeDirectory)
                await MainActor.run { [weak self] in
                    guard let self,
                          self.selectedSessionID == sessionID,
                          self.selectedContextInfo?.linearIssueID == issueID,
                          self.selectedLinearIssueIdentifier == issueID else {
                        return
                    }
                    self.linearIssueDetailsCache[issueID] = issue
                    if self.selectedLinearIssueDetails != issue { self.selectedLinearIssueDetails = issue }
                    self.mergeLinearWorkflowStates(issue.workflowStates)
                    if self.selectedLinearIssueLoadState != .loaded { self.selectedLinearIssueLoadState = .loaded }
                    self.startSelectedLinearIssueStatusRefreshIfNeeded()
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self,
                          self.selectedSessionID == sessionID,
                          self.selectedContextInfo?.linearIssueID == issueID,
                          self.selectedLinearIssueIdentifier == issueID else {
                        return
                    }
                    if self.linearIssueDetailsCache[issueID] != nil
                        || self.selectedLinearIssueDetails?.identifier == issueID {
                        self.selectedLinearIssueLoadState = .loaded
                        self.startSelectedLinearIssueStatusRefreshIfNeeded()
                    } else {
                        self.selectedLinearIssueLoadState = .failed(LinearIssueClient.message(for: error))
                        self.stopSelectedLinearIssueStatusRefresh()
                    }
                }
            }
        }
    }

    func updateSelectedLinearIssueState(_ state: LinearWorkflowState) {
        guard let session = selectedSession,
              session.status != .closed,
              let issueID = selectedContextInfo?.linearIssueID else {
            return
        }

        selectedLinearIssueTask?.cancel()
        selectedLinearIssueIdentifier = issueID
        selectedLinearIssueLoadState = .updating(state.name)

        let cwd = session.cwd
        let sessionID = session.id
        let environment = self.environment
        let homeDirectory = self.homeDirectory
        selectedLinearIssueTask = Task.detached(priority: .userInitiated) { [environment, homeDirectory] in
            do {
                try await LinearIssueClient.updateIssueState(identifier: issueID, state: state, cwd: cwd, environment: environment, homeDirectory: homeDirectory)
                let status = try await LinearIssueClient.fetchIssueStatus(identifier: issueID, cwd: cwd, environment: environment, homeDirectory: homeDirectory)
                await MainActor.run { [weak self] in
                    guard let self,
                          self.selectedSessionID == sessionID,
                          self.selectedContextInfo?.linearIssueID == issueID,
                          self.selectedLinearIssueIdentifier == issueID else {
                        return
                    }
                    self.applySelectedLinearIssueStatus(status)
                    self.selectedLinearIssueLoadState = .loaded
                    self.startSelectedLinearIssueStatusRefreshIfNeeded()
                    self.refreshSelectedContextInfo(force: true)
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self,
                          self.selectedSessionID == sessionID,
                          self.selectedContextInfo?.linearIssueID == issueID,
                          self.selectedLinearIssueIdentifier == issueID else {
                        return
                    }
                    self.selectedLinearIssueLoadState = .failed(LinearIssueClient.message(for: error, action: "update"))
                }
            }
        }
    }

    func updateSelectedLinearIssueDescription(taskIndex: Int) {
        guard let session = selectedSession, session.status != .closed,
              let issueID = selectedContextInfo?.linearIssueID,
              let issue = selectedLinearIssueDetails, let description = issue.description,
              let newDescription = MarkdownTaskListEditor.toggledDescription(description, taskIndex: taskIndex) else { return }
        pendingSelectedLinearDescriptionUpdate = .init(issueID: issueID, oldDescription: issue.description, newDescription: newDescription)
        let optimistic = issue.applying(description: newDescription)
        selectedLinearIssueDetails = optimistic
        linearIssueDetailsCache[issueID] = optimistic
        selectedLinearIssueLoadState = .updatingDescription
        saveSelectedLinearIssueDescription(issueID: issueID, description: newDescription, cwd: session.cwd, sessionID: session.id)
    }

    func retrySelectedLinearIssueDescription() {
        guard let pending = pendingSelectedLinearDescriptionUpdate, let session = selectedSession,
              selectedContextInfo?.linearIssueID == pending.issueID else { return }
        selectedLinearIssueLoadState = .updatingDescription
        saveSelectedLinearIssueDescription(issueID: pending.issueID, description: pending.newDescription, cwd: session.cwd, sessionID: session.id)
    }

    private func saveSelectedLinearIssueDescription(issueID: String, description: String, cwd: String, sessionID: String) {
        selectedLinearIssueTask?.cancel()
        let environment = self.environment
        let homeDirectory = self.homeDirectory
        selectedLinearIssueTask = Task.detached(priority: .userInitiated) { [environment, homeDirectory] in
            do {
                try await LinearIssueClient.updateIssueDescription(identifier: issueID, description: description, cwd: cwd, environment: environment, homeDirectory: homeDirectory)
                await MainActor.run { [weak self] in
                    guard let self, self.selectedSessionID == sessionID, self.selectedContextInfo?.linearIssueID == issueID else { return }
                    self.pendingSelectedLinearDescriptionUpdate = nil
                    self.selectedLinearIssueTask = nil
                    self.selectedLinearIssueLoadState = .loaded
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.selectedSessionID == sessionID, self.selectedContextInfo?.linearIssueID == issueID else { return }
                    self.selectedLinearIssueTask = nil
                    if let pending = self.pendingSelectedLinearDescriptionUpdate, let issue = self.selectedLinearIssueDetails {
                        let reverted = issue.applying(description: pending.oldDescription)
                        self.selectedLinearIssueDetails = reverted
                        self.linearIssueDetailsCache[issueID] = reverted
                    }
                    self.selectedLinearIssueLoadState = .failed("Unable to save description")
                }
            }
        }
    }

    func updateSelectedLinearListIssueDescription(taskIndex: Int) {
        guard let issueID = selectedLinearListIssueID, let issue = selectedLinearListIssueDetails,
              let description = issue.description,
              let newDescription = MarkdownTaskListEditor.toggledDescription(description, taskIndex: taskIndex) else { return }
        pendingSelectedLinearListDescriptionUpdate = .init(issueID: issueID, oldDescription: issue.description, newDescription: newDescription)
        let optimistic = issue.applying(description: newDescription)
        selectedLinearListIssueDetails = optimistic
        linearIssueDetailsCache[issueID] = optimistic
        selectedLinearListIssueLoadState = .updatingDescription
        saveSelectedLinearListIssueDescription(issueID: issueID, description: newDescription, cwd: selectedSession?.cwd ?? homeDirectory)
    }

    func retrySelectedLinearListIssueDescription() {
        guard let pending = pendingSelectedLinearListDescriptionUpdate, selectedLinearListIssueID == pending.issueID else { return }
        selectedLinearListIssueLoadState = .updatingDescription
        saveSelectedLinearListIssueDescription(issueID: pending.issueID, description: pending.newDescription, cwd: selectedSession?.cwd ?? homeDirectory)
    }

    private func saveSelectedLinearListIssueDescription(issueID: String, description: String, cwd: String) {
        selectedLinearListIssueTask?.cancel()
        let environment = self.environment
        let homeDirectory = self.homeDirectory
        selectedLinearListIssueTask = Task.detached(priority: .userInitiated) { [environment, homeDirectory] in
            do {
                try await LinearIssueClient.updateIssueDescription(identifier: issueID, description: description, cwd: cwd, environment: environment, homeDirectory: homeDirectory)
                await MainActor.run { [weak self] in
                    guard let self, self.selectedLinearListIssueID == issueID else { return }
                    self.pendingSelectedLinearListDescriptionUpdate = nil
                    self.selectedLinearListIssueTask = nil
                    self.selectedLinearListIssueLoadState = .loaded
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.selectedLinearListIssueID == issueID else { return }
                    self.selectedLinearListIssueTask = nil
                    if let pending = self.pendingSelectedLinearListDescriptionUpdate, let issue = self.selectedLinearListIssueDetails {
                        let reverted = issue.applying(description: pending.oldDescription)
                        self.selectedLinearListIssueDetails = reverted
                        self.linearIssueDetailsCache[issueID] = reverted
                    }
                    self.selectedLinearListIssueLoadState = .failed("Unable to save description")
                }
            }
        }
    }

    private func startSelectedLinearIssueStatusRefreshIfNeeded() {
        guard selectedLinearIssueStatusTimer == nil,
              selectedLinearIssueDetails != nil,
              selectedLinearIssueIdentifier != nil else {
            return
        }

        // Linear does not expose an app-local status change event here, so keep polling
        // scoped to the selected loaded issue and only fetch the lightweight status fields.
        selectedLinearIssueStatusTimer = Timer.scheduledTimer(withTimeInterval: 20.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshSelectedLinearIssueStatus()
            }
        }
    }

    private func stopSelectedLinearIssueStatusRefresh() {
        selectedLinearIssueStatusTimer?.invalidate()
        selectedLinearIssueStatusTimer = nil
    }

    func refreshSelectedLinearIssueStatus() {
        // Network poll whose only product is the issue chip in the detail panel.
        // Nothing on screen means nothing to keep fresh; becoming visible forces one.
        guard SessionBackgroundRefreshPolicy.refreshesOnScreenChrome(
            activityLevel: supervisorActivityLevel
        ) else { return }
        guard let session = selectedSession,
              session.status != .closed,
              let issueID = selectedLinearIssueIdentifier,
              selectedLinearIssueDetails?.identifier == issueID,
              selectedLinearIssueStatusTask == nil,
              selectedLinearIssueLoadState == .loaded,
              Date().isAtOrAfter(selectedLinearIssueStatusRetryAfter) else {
            return
        }

        let cwd = session.cwd
        let sessionID = session.id
        let environment = self.environment
        let homeDirectory = self.homeDirectory
        selectedLinearIssueStatusTask = Task.detached(priority: .utility) { [environment, homeDirectory] in
            do {
                let status = try await LinearIssueClient.fetchIssueStatus(identifier: issueID, cwd: cwd, environment: environment, homeDirectory: homeDirectory)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.selectedLinearIssueStatusTask = nil
                    self.selectedLinearIssueStatusRetryAfter = .distantPast
                    guard self.selectedSessionID == sessionID,
                          self.selectedContextInfo?.linearIssueID == issueID,
                          self.selectedLinearIssueIdentifier == issueID else {
                        return
                    }
                    self.applySelectedLinearIssueStatus(status)
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.selectedLinearIssueStatusTask = nil
                    // Keep the timer, but cool down failed requests. This avoids
                    // spawning a CLI process every 20 seconds when cached issue
                    // data is available but Linear auth/network access is not.
                    self.selectedLinearIssueStatusRetryAfter = Date().addingTimeInterval(300)
                }
            }
        }
    }

    private func applySelectedLinearIssueStatus(_ status: LinearIssueStatusSnapshot) {
        guard status.identifier == selectedLinearIssueIdentifier,
              let issue = selectedLinearIssueDetails else {
            return
        }
        let updatedIssue = issue.applying(status: status)
        // The status poll usually returns the current value. Publishing it
        // again rebuilds the scene and the entire selected issue panel.
        if updatedIssue != issue {
            selectedLinearIssueDetails = updatedIssue
        }
        linearIssueDetailsCache[updatedIssue.identifier] = updatedIssue
        mergeLinearWorkflowStates(status.workflowStates)
    }
}
