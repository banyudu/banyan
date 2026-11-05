import BanyanCore
import Foundation
import AppKit
import SwiftUI

extension SessionStore {
    /// Re-resolves repository context for sessions whose git lookups failed to
    /// run (timed out / couldn't launch). The restore pass above spawns git for
    /// every unique cwd in one burst; lookups that degrade there leave the
    /// session stuck with a path-based group (worktrees then don't group with
    /// their repo) because nothing else re-runs the lookup for an idle pane.
    /// Runs the lookups off the main thread, then applies trustworthy results.
    func retryDegradedDisplayContexts() {
        guard displayContextRetryTask == nil else { return }
        guard displayContextRetryAttempts < 5 else { return }
        let candidates = sessions.filter { $0.status != .closed && $0.displayContextDegraded }
        guard !candidates.isEmpty else { return }
        displayContextRetryAttempts += 1
        let lookups = Set(candidates.map(\.cwd)).map { cwd in
            (cwd: cwd, homeDirectory: homeDirectory, environment: environment)
        }
        displayContextRetryTask = Task.detached(priority: .utility) { [weak self] in
            var resolved: [String: SessionProjectContext] = [:]
            for lookup in lookups {
                resolved[lookup.cwd] = SessionDisplayLabel.cachedContext(
                    cwd: lookup.cwd,
                    homeDirectory: lookup.homeDirectory,
                    environment: lookup.environment
                )
            }
            let contextsByCWD = resolved
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.displayContextRetryTask = nil
                var stillDegraded = false
                for session in self.sessions where session.status != .closed && session.displayContextDegraded {
                    guard let context = contextsByCWD[session.cwd] else { continue }
                    session.applyProjectContext(context)
                    stillDegraded = stillDegraded || session.displayContextDegraded
                }
                self.saveSessions()
                if stillDegraded {
                    // Try again shortly; git may have been transiently overloaded.
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 15_000_000_000)
                        self?.retryDegradedDisplayContexts()
                    }
                }
            }
        }
    }

    /// Periodically refresh the branch-derived issue binding even when the
    /// pane's current directory hasn't changed. `git checkout main` in the same
    /// directory doesn't trigger `onDirectoryChange`/`currentPath` observation, so
    /// without polling the chip would keep showing the previous ENG until the next
    /// full cwd change. Throttled per-cwd and shared across sessions in the same
    /// directory to keep git load low.
    func refreshBranchContextsIfNeeded(force: Bool = false) {
        guard branchRefreshTask == nil else { return }
        // Each cycle spawns several `git` invocations per distinct working
        // directory, and the chip it feeds is pure chrome. While nothing is on
        // screen there is no chip to keep honest, so the sweep stops outright;
        // becoming visible forces one before the user can read a stale branch.
        let refreshInterval = SessionBackgroundRefreshPolicy.branchRefreshInterval(
            activityLevel: supervisorActivityLevel
        )
        guard force || refreshInterval != nil else { return }
        let throttle = refreshInterval ?? SessionBackgroundRefreshPolicy.activeBranchRefreshInterval
        let now = Date()
        let candidates = sessions.filter { $0.status != .closed && !$0.isSuspended }
        guard !candidates.isEmpty else { return }
        // Group by cwd so one git lookup covers all sessions in that directory.
        var cwds: Set<String> = []
        for session in candidates {
            let last = lastBranchRefreshByCWD[session.cwd]
            if force || last == nil || now.timeIntervalSince(last!) >= throttle {
                cwds.insert(session.cwd)
            }
        }
        guard !cwds.isEmpty else { return }
        for cwd in cwds {
            lastBranchRefreshByCWD[cwd] = now
        }
        // Cap total git work per cycle so a large workspace doesn't spike.
        let limited = Array(cwds.prefix(20))
        let home = homeDirectory
        let env = environment
        branchRefreshTask = Task.detached(priority: .utility) { [weak self] in
            var contexts: [String: SessionProjectContext] = [:]
            for cwd in limited {
                contexts[cwd] = SessionDisplayLabel.cachedContext(cwd: cwd, homeDirectory: home, environment: env)
            }
            let resolved = contexts
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.branchRefreshTask = nil
                var didUpdate = false
                for session in self.sessions where session.status != .closed && !session.isSuspended {
                    guard let context = resolved[session.cwd] else { continue }
                    // Only apply if the lookup was trustworthy; degraded results
                    // must not clobber the last good branch (handled by
                    // updateDisplayContext's degraded guard).
                    if context.gitLookupDegraded { continue }
                    let before = session.displayBranch
                    let beforeURL = session.titleURL
                    session.applyProjectContext(context)
                    if session.displayBranch != before || session.titleURL != beforeURL {
                        didUpdate = true
                    }
                }
                if didUpdate {
                    self.saveSessions()
                    self.refreshSelectedContextInfo(force: true)
                }
            }
        }
    }

    func openSelectedPullRequest() {
        if let url = selectedPullRequestURL {
            NSWorkspace.shared.open(url)
            return
        }
        resolveSelectedContextForOpenPullRequest()
    }

    func showSelectedPullRequestPreview() {
        isPullRequestPreviewPresented = true
        refreshSelectedPullRequestPreview()
    }

    func closePullRequestPreview() {
        selectedPullRequestTask?.cancel()
        selectedPullRequestTask = nil
        selectedPullRequestPreviewURL = nil
        if selectedPullRequestDetails != nil { selectedPullRequestDetails = nil }
        if selectedPullRequestLoadState != .idle { selectedPullRequestLoadState = .idle }
        if isPullRequestPreviewPresented { isPullRequestPreviewPresented = false }
    }

    func refreshSelectedPullRequestPreview(force: Bool = false) {
        guard isPullRequestPreviewPresented,
              let session = selectedSession,
              session.status != .closed else {
            closePullRequestPreview()
            return
        }

        if let url = selectedPullRequestURL {
            fetchSelectedPullRequestPreview(url: url, cwd: session.cwd, sessionID: session.id, force: force)
            return
        }

        resolveSelectedContextForPullRequestPreview()
    }

    var selectedLinearIssueURL: URL? {
        if let value = selectedContextInfo?.linearIssueURL, let url = URL(string: value) {
            return url
        }
        return nil
    }

    var selectedLinearListIssueURL: URL? {
        if let value = selectedLinearListIssueDetails?.url, let url = URL(string: value) {
            return url
        }
        if let value = linearIssues.first(where: { $0.identifier == selectedLinearListIssueID })?.url,
           let url = URL(string: value) {
            return url
        }
        guard let selectedLinearListIssueID else { return nil }
        return URL(string: LinearIssueReference.issueURL(
            for: selectedLinearListIssueID,
            environment: environment
        ))
    }

    var selectedLinearListIssueContext: SessionContextInfo? {
        guard let issueID = selectedLinearListIssueID else { return nil }
        let title = selectedLinearListIssueDetails?.title
            ?? linearIssues.first(where: { $0.identifier == issueID })?.title
        let url = selectedLinearListIssueURL?.absoluteString
        return SessionContextInfo(
            sessionID: "linear-list",
            signature: issueID,
            linearIssueID: issueID,
            linearIssueTitle: title,
            linearIssueURL: url,
            githubIssueNumber: nil,
            githubIssueTitle: nil,
            githubIssueURL: nil,
            pullRequestNumber: nil,
            pullRequestTitle: nil,
            pullRequestURL: nil
        )
    }

    var selectedPullRequestURL: URL? {
        let value = selectedPullRequestDetails?.url ?? selectedContextInfo?.pullRequestURL
        guard let value else { return nil }
        return URL(string: value)
    }

    var canAttemptSelectedPullRequestPreview: Bool {
        guard let selectedSession else { return false }
        return selectedSession.status != .closed
    }

    var selectedPullRequestPreviewContext: SessionContextInfo? {
        if let selectedContextInfo {
            return selectedContextInfo
        }
        guard let selectedSession else { return nil }
        return SessionContextInfo(
            sessionID: selectedSession.id,
            signature: selectedSession.id,
            linearIssueID: nil,
            linearIssueTitle: nil,
            linearIssueURL: nil,
            githubIssueNumber: nil,
            githubIssueTitle: nil,
            githubIssueURL: nil,
            pullRequestNumber: nil,
            pullRequestTitle: nil,
            pullRequestURL: nil
        )
    }

    /// Returns a non-expired cached context for `input`, reidentified to the current
    /// session/signature. Lets user-triggered PR flows reuse a recent result instead
    /// of always re-spawning `linear`/`gh`.
    private func freshCachedSelectedContext(for input: SessionContextLookupInput) -> SessionContextInfo? {
        let key = SessionContextResolver.cacheKey(for: input)
        guard let cached = selectedContextCache[key],
              Date().timeIntervalSince(cached.at) < selectedContextCacheTTL else {
            return nil
        }
        return cached.info.reidentified(sessionID: input.sessionID, signature: input.signature)
    }

    private func storeSelectedContext(_ info: SessionContextInfo, key: String) {
        selectedContextCache[key] = (info, Date())
        // Distinct keys are bounded by active projects/issues, but cap defensively.
        if selectedContextCache.count > 64,
           let oldest = selectedContextCache.min(by: { $0.value.at < $1.value.at })?.key {
            selectedContextCache.removeValue(forKey: oldest)
        }
    }

    func refreshSelectedContextInfo(force: Bool = false) {
        let trace = EnergyTrace.span("selectedContext.refresh", sessionID: selectedSessionID)
        defer { trace?.end() }
        guard let input = selectedContextLookupInput() else {
            selectedContextTask?.cancel()
            selectedContextTask = nil
            selectedContextSignature = nil
            selectedContextInfo = nil
            return
        }

        guard force || input.signature != selectedContextSignature else { return }

        selectedContextSignature = input.signature

        let cacheKey = SessionContextResolver.cacheKey(for: input)

        // Serve a fresh cached result instantly; this is the common case now that
        // the cache key ignores free-text title churn, so no subprocess is spawned.
        if let cached = selectedContextCache[cacheKey],
           Date().timeIntervalSince(cached.at) < selectedContextCacheTTL {
            selectedContextTask?.cancel()
            selectedContextTask = nil
            selectedContextInfo = cached.info.reidentified(
                sessionID: input.sessionID,
                signature: input.signature
            )
            selectedContextResolvedAt = Date()
            return
        }

        // Cache miss/expiry: show the subprocess-free fast fields immediately so the
        // titlebar isn't blank, then enrich from git/linear/gh in the background.
        selectedContextInfo = SessionContextResolver.resolveFast(input: input)
        selectedContextTask?.cancel()
        selectedContextTask = Task.detached(priority: .utility) { [telemetry = self.telemetry] in
            let startedAt = DispatchTime.now()
            let info = await SessionContextResolver.resolve(input: input) {
                Task.isCancelled
            }
            telemetry.recordDuration(
                "selected_context.resolve",
                durationMS: PerformanceTelemetry.elapsedMS(since: startedAt),
                sessionID: input.sessionID,
                detail: "signature=\(input.signature)"
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.storeSelectedContext(info, key: cacheKey)
                guard self.selectedSessionID == input.sessionID,
                      self.selectedContextSignature == input.signature else {
                    return
                }
                self.selectedContextInfo = info
                self.selectedContextResolvedAt = Date()
            }
        }
    }

    private func resolveSelectedContextForOpenPullRequest() {
        guard let input = selectedContextLookupInput() else { return }
        // Repeat clicks / already-resolved PRs: open straight from the fresh cache so
        // the action is instant and spawns no subprocess. Fall through to a fresh
        // resolve when the cache lacks a PR, so a newly-created PR is still discovered.
        if let cached = freshCachedSelectedContext(for: input),
           let value = cached.pullRequestURL, let url = URL(string: value) {
            selectedContextSignature = input.signature
            selectedContextInfo = cached
            selectedContextResolvedAt = Date()
            NSWorkspace.shared.open(url)
            return
        }
        selectedContextSignature = input.signature
        selectedContextTask?.cancel()
        selectedContextTask = Task.detached(priority: .userInitiated) { [telemetry = self.telemetry] in
            let startedAt = DispatchTime.now()
            let info = await SessionContextResolver.resolve(input: input) {
                Task.isCancelled
            }
            telemetry.recordDuration(
                "selected_context.resolve",
                durationMS: PerformanceTelemetry.elapsedMS(since: startedAt),
                sessionID: input.sessionID,
                detail: "signature=\(input.signature) open_pr"
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.storeSelectedContext(info, key: SessionContextResolver.cacheKey(for: input))
                guard self.selectedSessionID == input.sessionID,
                      self.selectedContextSignature == input.signature else {
                    return
                }
                self.selectedContextInfo = info
                self.selectedContextResolvedAt = Date()
                guard let value = info.pullRequestURL, let url = URL(string: value) else { return }
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func resolveSelectedContextForPullRequestPreview() {
        guard let input = selectedContextLookupInput() else {
            selectedPullRequestLoadState = .failed("No active session")
            return
        }

        selectedPullRequestLoadState = .loading
        selectedContextSignature = input.signature
        // Drive the preview from the fresh cache when it already knows the PR, avoiding
        // a redundant `linear`/`gh` resolve. A cache miss (or cached-but-no-PR) still
        // resolves fresh below so a just-created PR is picked up.
        if let cached = freshCachedSelectedContext(for: input),
           cached.pullRequestURL != nil {
            selectedContextTask?.cancel()
            selectedContextTask = nil
            selectedContextInfo = cached
            selectedContextResolvedAt = Date()
            if let session = selectedSession {
                let url = cached.pullRequestURL.flatMap(URL.init(string:))
                fetchSelectedPullRequestPreview(
                    url: url,
                    cwd: session.cwd,
                    sessionID: session.id,
                    force: true
                )
            } else {
                selectedPullRequestLoadState = .failed("No active session")
            }
            return
        }
        selectedContextTask?.cancel()
        selectedContextTask = Task.detached(priority: .userInitiated) { [telemetry = self.telemetry] in
            let startedAt = DispatchTime.now()
            let info = await SessionContextResolver.resolve(input: input) {
                Task.isCancelled
            }
            telemetry.recordDuration(
                "selected_context.resolve",
                durationMS: PerformanceTelemetry.elapsedMS(since: startedAt),
                sessionID: input.sessionID,
                detail: "signature=\(input.signature) pr_preview"
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.storeSelectedContext(info, key: SessionContextResolver.cacheKey(for: input))
                guard self.selectedSessionID == input.sessionID,
                      self.selectedContextSignature == input.signature,
                      self.isPullRequestPreviewPresented else {
                    return
                }
                self.selectedContextInfo = info
                self.selectedContextResolvedAt = Date()
                guard let session = self.selectedSession else {
                    self.selectedPullRequestLoadState = .failed("No active session")
                    return
                }
                let url = info.pullRequestURL.flatMap(URL.init(string:))
                self.fetchSelectedPullRequestPreview(
                    url: url,
                    cwd: session.cwd,
                    sessionID: session.id,
                    force: true
                )
            }
        }
    }

    private func fetchSelectedPullRequestPreview(
        url: URL?,
        cwd: String,
        sessionID: String,
        force: Bool
    ) {
        guard force || selectedPullRequestPreviewURL != url || selectedPullRequestDetails == nil else {
            selectedPullRequestLoadState = .loaded
            return
        }

        selectedPullRequestTask?.cancel()
        selectedPullRequestPreviewURL = url
        selectedPullRequestDetails = nil
        selectedPullRequestLoadState = .loading

        let environment = self.environment
        let homeDirectory = self.homeDirectory
        selectedPullRequestTask = Task.detached(priority: .utility) { [environment, homeDirectory] in
            do {
                let details = try await GitHubPullRequestClient.fetchPullRequest(
                    url: url,
                    cwd: cwd,
                    environment: environment,
                    homeDirectory: homeDirectory
                )
                await MainActor.run { [weak self] in
                    guard let self,
                          self.selectedSessionID == sessionID,
                          self.isPullRequestPreviewPresented,
                          self.selectedPullRequestPreviewURL == url else {
                        return
                    }
                    self.selectedPullRequestTask = nil
                    self.selectedPullRequestDetails = details
                    self.selectedPullRequestPreviewURL = URL(string: details.url)
                    self.selectedPullRequestLoadState = .loaded
                }
            } catch {
                let message = GitHubPullRequestClient.message(for: error)
                await MainActor.run { [weak self] in
                    guard let self,
                          self.selectedSessionID == sessionID,
                          self.isPullRequestPreviewPresented,
                          self.selectedPullRequestPreviewURL == url else {
                        return
                    }
                    self.selectedPullRequestTask = nil
                    self.selectedPullRequestLoadState = .failed(message)
                }
            }
        }
    }

    private func selectedContextLookupInput() -> SessionContextLookupInput? {
        guard let session = selectedSession, session.status != .closed, !session.isSuspended else {
            return nil
        }
        return SessionContextLookupInput(
            sessionID: session.id,
            cwd: session.cwd,
            homeDirectory: homeDirectory,
            environment: environment,
            title: session.title,
            titleURL: session.titleURL,
            displayTitle: session.displayTitle,
            branch: session.displayBranch
        )
    }

    func refreshSelectedContextInfoIfStale() {
        guard Date().timeIntervalSince(selectedContextResolvedAt) > 30 else { return }
        refreshSelectedContextInfo(force: true)
    }
}
