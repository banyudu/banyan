import Foundation
import BanyanCore

extension BanyanSession {
    var displayTitle: String {
        SessionDisplayPolicy.displayTitle(
            title: title,
            isTitlePinned: isTitlePinned,
            reportedTitle: reportedTitle,
            generatedTitle: generatedTitle,
            cwd: cwd,
            homeDirectory: homeDirectory,
            detectedProvider: detectedAgentProvider,
            command: command
        )
    }

    var persistenceSnapshot: SessionSnapshot {
        SessionSnapshot(
            id: id,
            tmuxSessionName: tmuxSessionName,
            title: title,
            titleURL: titleURL,
            titleURLWasAutoDetected: titleURLWasAutoDetected,
            reportedTitle: reportedTitle,
            generatedTitle: generatedTitle,
            isTitlePinned: isTitlePinned,
            cwd: cwd,
            command: command,
            status: status,
            tone: tone,
            parentSessionID: parentSessionID,
            agentSessionID: agentSessionID,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    /// `titleURL` comes first because the sidebar renders this as the label of a link
    /// *to* that URL: reading the ID off a title from an earlier chapter would show
    /// one issue and open another. The title and cwd only fill in when nothing is bound.
    var titleLinkLabel: String? {
        LinearIssueReference.preferredID(
            titleURL: titleURL,
            title: title,
            branch: displayBranch,
            cwd: cwd,
            environment: environment
        )
    }

    var agentProvider: CodingAgentProvider? {
        SessionDisplayPolicy.agentProvider(
            command: command,
            detectedProvider: detectedAgentProvider
        )
    }

    /// Provider to show in the live sidebar row. Normally the launched identity,
    /// but once the agent process exits the supervisor reports a bare-shell
    /// `.running` pane — then this drops to nil so the row renders like a plain
    /// shell instead of a stale agent (no provider icon, no idle-agent affordances).
    /// `agentProvider` (the launched identity) is intentionally left intact so
    /// reopen/resume still know what this session was. A live agent is never
    /// `.running` (the supervisor only emits it when no agent process is alive), so
    /// this never hides the icon for a genuinely running agent.
    var displayAgentProvider: CodingAgentProvider? {
        SessionDisplayPolicy.displayAgentProvider(
            status: status,
            command: command,
            detectedProvider: detectedAgentProvider
        )
    }

    var needsManualAttach: Bool {
        SessionRestorationPolicy.needsManualAttach(
            isRestored: isRestored,
            isProcessStarted: isProcessStarted,
            status: status,
            needsRecovery: needsRecovery
        )
    }

    var isImportedHistory: Bool {
        historyTranscriptURL != nil
    }

    var canDispatchHandoff: Bool {
        SessionHandoffPolicy.canDispatch(
            isImportedHistory: isImportedHistory,
            provider: agentProvider,
            status: status,
            isGitWorktree: displayIsGitWorktree,
            branch: displayBranch,
            isDefaultBranch: displayIsDefaultBranch
        )
    }
}
