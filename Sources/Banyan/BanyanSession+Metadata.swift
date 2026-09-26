import BanyanCore
import Foundation

extension BanyanSession {
    func mark(status: SessionStatus? = nil, tone: SessionTone? = nil, title: String? = nil, titleURL: String? = nil) {
        if let status {
            let changed = self.status != status
            self.status = status
            if changed {
                onStatusSignal?(status)
            }
        }
        if let tone {
            self.tone = tone
        }
        if let title, !title.isEmpty {
            self.title = title
            isTitlePinned = true
        }
        if let titleURL {
            self.titleURL = SessionInputPolicy.normalizedTitleURL(titleURL)
            titleURLWasAutoDetected = false
        }
        refreshGeneratedTitle()
        touch()
    }

    func markDetectedAgentProvider(_ provider: CodingAgentProvider?) {
        guard detectedAgentProvider != provider else { return }
        detectedAgentProvider = provider
        refreshGeneratedTitle()
        touch()
    }

    func markDetectedAgentModel(_ modelID: String?, isExact: Bool) {
        guard detectedAgentModelID != modelID || detectedAgentModelIDIsExact != isExact else { return }
        detectedAgentModelID = modelID
        detectedAgentModelIDIsExact = isExact
    }

    func markAgentSessionID(_ sessionID: String?) {
        guard let sessionID, !sessionID.isEmpty, agentSessionID != sessionID else { return }
        agentSessionID = sessionID
        agentTitleImportAttempts = 0
        touch()
    }

    func noteUserSubmittedInput(_ submittedInput: String? = nil) {
        if SessionInputPolicy.isConversationResetCommand(submittedInput), agentProvider != nil {
            lastConversationResetAt = Date()
            if !hasUsefulPinnedTitle {
                reportedTitle = nil
                generatedTitle = nil
                externalTitleSignature = nil
            }
            touch()
        } else {
            markSubmittedPromptTitle(submittedInput)
        }
        if let nextStatus = SessionInputPolicy.statusAfterSubmittedInput(
            isImportedHistory: isImportedHistory,
            isProcessStarted: isProcessStarted,
            status: status,
            provider: agentProvider
        ) {
            mark(status: nextStatus, tone: .blue)
        }
        onUserSubmittedInput?(submittedInput)
    }

    /// Drop a stale title when the agent transcript shows the current segment
    /// was reset (/clear or /new) with no prompt since. Mirrors the reset
    /// branch of `noteUserSubmittedInput`, but is driven by transcript
    /// observation rather than keystroke capture, so it also fires for resets
    /// the keystroke monitor never saw. Idempotent and pin-safe.
    func noteConversationResetFromTranscript() {
        guard !hasUsefulPinnedTitle else { return }
        guard reportedTitle != nil || generatedTitle != nil || externalTitleSignature != nil else { return }
        reportedTitle = nil
        generatedTitle = nil
        externalTitleSignature = nil
        touch()
    }

    func markFirstPromptTitle(_ title: String) {
        guard !hasUsefulPinnedTitle else { return }
        guard let provider = agentProvider, [.claude, .codex].contains(provider) else { return }
        guard let promptTitle = SessionTitleGenerator.titleFromPrompt(title) else { return }
        guard reportedTitle != promptTitle else { return }
        reportedTitle = promptTitle
        refreshGeneratedTitle()
        touch()
    }

    /// Adopt the title the coding agent generated for the conversation itself.
    /// Codex publishes one a few seconds after the first prompt, and it reads
    /// better than anything derived from the prompt text, so it replaces the
    /// prompt title in place — a rename the sidebar shows mid-conversation.
    func markAgentGeneratedTitle(_ title: String) {
        guard !hasUsefulPinnedTitle else { return }
        guard let provider = agentProvider, [.claude, .codex].contains(provider) else { return }
        guard let agentTitle = SessionTitleGenerator.sanitizeTitle(title),
              SessionTitleGenerator.isUsefulTitle(agentTitle) else { return }
        guard reportedTitle != agentTitle else { return }
        reportedTitle = agentTitle
        refreshGeneratedTitle()
        touch()
    }

    private func markSubmittedPromptTitle(_ submittedInput: String?) {
        guard !hasUsefulPinnedTitle, usefulAgentTitle == nil, agentProvider != nil else { return }
        guard let promptTitle = SessionInputPolicy.submittedPromptTitle(from: submittedInput) else { return }
        reportedTitle = promptTitle
        refreshGeneratedTitle()
        touch()
    }

    func updateCurrentDirectory(_ directory: String?) {
        guard let directory = SessionInputPolicy.normalizedDirectory(directory) else { return }
        // A background async update may already be in flight for this directory.
        // Bumping the generation here invalidates it so its stale git result
        // cannot clobber the synchronous result below.
        directoryUpdateGeneration &+= 1
        // HEAD-mtime-gated cache shared with the branch timer and supervisor,
        // so a burst of directory updates reuses one git answer.
        let displayContext = SessionDisplayLabel.cachedContext(
            cwd: directory,
            homeDirectory: homeDirectory,
            environment: environment
        )
        guard directory != cwd else {
            applyProjectContext(displayContext)
            if !displayContext.gitLookupDegraded {
                onProjectContextObserved?(directory, displayContext)
            }
            return
        }
        let shouldUpdateTitle = SessionInputPolicy.titleTracksCurrentDirectory(
            title,
            isTitlePinned: isTitlePinned,
            cwd: cwd,
            homeDirectory: homeDirectory
        )
        cwd = directory
        updateDisplayContext(displayContext)
        if shouldUpdateTitle {
            title = titleForCurrentDirectory(directory)
        }
        refreshAutoDetectedTitleURL()
        refreshGeneratedTitle()
        touch()
        if !displayContext.gitLookupDegraded {
            onProjectContextObserved?(directory, displayContext)
        }
    }

    /// Async variant for terminal OSC7 directory notifications, which fire on the
    /// main thread during streaming agent output. The git lookups (up to ~6
    /// subprocesses, 5s timeout each) run on a background task; the cwd itself is
    /// applied immediately so the UI never shows a stale path, and the
    /// repository context follows when the lookup completes. Rapid `cd`s are
    /// coalesced by generation — only the latest directory's result is applied.
    ///
    /// Same-directory notifications (the common OSC7 repeat on every prompt) are
    /// skipped: branch changes without a `cd` are covered by the periodic
    /// branch refresh, so re-running git on every prompt would be a storm.
    func updateCurrentDirectoryAsync(_ directory: String?) {
        guard let directory = SessionInputPolicy.normalizedDirectory(directory) else { return }
        guard directory != cwd else { return }
        directoryUpdateGeneration &+= 1
        let generation = directoryUpdateGeneration
        let shouldUpdateTitle = SessionInputPolicy.titleTracksCurrentDirectory(
            title,
            isTitlePinned: isTitlePinned,
            cwd: cwd,
            homeDirectory: homeDirectory
        )
        // Show the new path immediately; repository context catches up below.
        cwd = directory
        if shouldUpdateTitle {
            title = titleForCurrentDirectory(directory)
        }
        touch()
        let homeDirectory = homeDirectory
        let environment = environment
        Task.detached(priority: .utility) { [weak self] in
            // Shared HEAD-mtime-gated cache: a burst of directory updates across
            // sibling panes reuses one git answer instead of forking per pane.
            let displayContext = SessionDisplayLabel.cachedContext(
                cwd: directory,
                homeDirectory: homeDirectory,
                environment: environment
            )
            await MainActor.run { [weak self] in
                guard let self,
                      self.directoryUpdateGeneration == generation,
                      self.cwd == directory else {
                    return
                }
                self.updateDisplayContext(displayContext)
                self.refreshAutoDetectedTitleURL()
                self.refreshGeneratedTitle()
                self.touch()
                if !displayContext.gitLookupDegraded {
                    self.onProjectContextObserved?(directory, displayContext)
                }
            }
        }
    }

    /// Apply one repository lookup to this session. SessionStore shares the same
    /// result with sibling panes in this directory so a branch switch updates every
    /// affected row without running duplicate git commands per session.
    func applyProjectContext(_ displayContext: SessionProjectContext) {
        let previousProject = displayProject
        let previousBranch = displayBranch
        let previousIsGitWorktree = displayIsGitWorktree
        let previousIsDefaultBranch = displayIsDefaultBranch
        let previousGroupID = projectGroupID
        let previousGroupTitle = projectGroupTitle
        let previousDegraded = displayContextDegraded
        let previousTitleURL = titleURL
        updateDisplayContext(displayContext)
        refreshAutoDetectedTitleURL()
        let contextChanged = previousProject != displayProject
            || previousBranch != displayBranch
            || previousIsGitWorktree != displayIsGitWorktree
            || previousIsDefaultBranch != displayIsDefaultBranch
            || previousGroupID != projectGroupID
            || previousGroupTitle != projectGroupTitle
            || previousDegraded != displayContextDegraded
        guard contextChanged || titleURL != previousTitleURL else { return }
        refreshGeneratedTitle()
        touch()
    }

    private var usefulAgentTitle: String? {
        SessionDisplayPolicy.usefulAgentTitle(reportedTitle)
    }

    private var hasUsefulPinnedTitle: Bool {
        SessionDisplayPolicy.hasUsefulPinnedTitle(
            title: title,
            isTitlePinned: isTitlePinned,
            cwd: cwd,
            homeDirectory: homeDirectory
        )
    }

    func refreshGeneratedTitle() {
        guard !hasUsefulPinnedTitle else { return }
        guard agentProvider != nil else {
            generatedTitle = nil
            return
        }
        let titleCommand = lastConversationResetAt == nil
            ? command
            : (agentProvider?.defaultExecutableName ?? command)
        let context = SessionTitleContext(
            id: id,
            baseTitle: title,
            isTitlePinned: hasUsefulPinnedTitle,
            cwd: cwd,
            project: displayProject,
            branch: displayBranch,
            command: titleCommand,
            reportedTitle: reportedTitle,
            provider: agentProvider
        )
        if let localTitle = SessionTitleGenerator.automaticTitle(for: context), localTitle != generatedTitle {
            generatedTitle = localTitle
        }
        requestExternalGeneratedTitleIfNeeded(context: context)
    }

    private func updateDisplayContext(_ displayContext: SessionProjectContext) {
        // A degraded lookup can't be trusted to say "no branch / not a worktree".
        // Keep the last reading and retry later rather than clobbering it with a
        // transient false-negative. This also prevents a second consecutive failure
        // from replacing the trustworthy reading retained after the first one.
        guard !displayContext.gitLookupDegraded else {
            displayContextDegraded = true
            return
        }
        displayProject = displayContext.project
        displayBranch = displayContext.branch
        displayIsGitWorktree = displayContext.isGitWorktree
        displayIsDefaultBranch = displayContext.isDefaultBranch
        projectGroupID = displayContext.groupID
        projectGroupTitle = displayContext.groupTitle
        displayContextDegraded = displayContext.gitLookupDegraded
    }

    /// Keeps the issue binding tracking the pane's current working directory and
    /// branch, which is where a session's identity actually lives: `cd` into another
    /// issue's worktree and the link follows. A binding the cwd/branch no longer
    /// supports is stale — a pane that has moved on, or an agent that marked the
    /// session and has since exited — so detection replaces it rather than deferring
    /// to it. Only an explicit binding (`banyanctl mark --title-url`) with nothing to
    /// detect survives, since that is a deliberate choice about a directory that says
    /// nothing on its own.
    private func refreshAutoDetectedTitleURL() {
        guard let detectedReference = LinearIssueReference.detect(
            branch: displayBranch,
            cwd: cwd,
            isGitWorktree: displayIsGitWorktree,
            environment: environment
        ) else {
            if titleURLWasAutoDetected {
                titleURL = nil
                titleURLWasAutoDetected = false
            }
            return
        }

        titleURLWasAutoDetected = true
        guard titleURL != detectedReference.url else { return }
        titleURL = detectedReference.url
    }

    private func titleForCurrentDirectory(_ cwd: String) -> String {
        PathDisplayName.make(path: cwd, homeDirectory: homeDirectory)
    }

    private func requestExternalGeneratedTitleIfNeeded(context: SessionTitleContext) {
        let environment = self.environment
        guard ExternalSessionTitleGenerator.isConfigured(environment: environment) else { return }
        let signature = [
            context.id,
            context.command,
            context.cwd,
            context.reportedTitle ?? "",
            context.provider?.rawValue ?? ""
        ].joined(separator: "\u{1f}")
        guard signature != externalTitleSignature else { return }
        externalTitleSignature = signature
        externalTitleTask?.cancel()

        externalTitleTask = Task.detached(priority: .utility) { [weak self] in
            guard let title = ExternalSessionTitleGenerator.generateTitle(
                for: context,
                environment: environment
            ) else { return }
            await MainActor.run { [weak self] in
                guard let self, !self.hasUsefulPinnedTitle, self.agentProvider != nil else { return }
                self.generatedTitle = title
                self.touch()
            }
        }
    }

}
