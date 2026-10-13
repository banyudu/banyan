import Foundation

public struct SessionRestorationPlan: Sendable, Equatable {
    public let tmuxSessionName: String
    public let status: SessionStatus
    public let needsRecovery: Bool

    public init(
        tmuxSessionName: String,
        status: SessionStatus,
        needsRecovery: Bool
    ) {
        self.tmuxSessionName = tmuxSessionName
        self.status = status
        self.needsRecovery = needsRecovery
    }
}

/// Produces the runtime fields needed to turn a persisted row into a live
/// frontend session.
public enum SessionRestorationPolicy {
    public static func needsManualAttach(
        isRestored: Bool,
        isProcessStarted: Bool,
        status: SessionStatus,
        needsRecovery: Bool
    ) -> Bool {
        isRestored && !isProcessStarted && (status == .failed || needsRecovery)
    }

    public static func restoredTitle(
        for snapshot: SessionSnapshot,
        homeDirectory: String
    ) -> String {
        if !snapshot.isTitlePinned, SessionTitleGenerator.isGenericDefaultTitle(snapshot.title) {
            return PathDisplayName.make(path: snapshot.cwd, homeDirectory: homeDirectory)
        }
        return snapshot.title
    }

    public static func plan(
        for snapshot: SessionSnapshot,
        liveTmuxSessionNames: Set<String>
    ) -> SessionRestorationPlan {
        let tmuxSessionName = snapshot.launchRequest.sessionName
        // Completed agents still have an original launch prompt. Selecting a
        // restored row must not recreate a missing pane with that prompt.
        let missingAgentBackend = snapshot.status != .closed
            && CodingAgentProvider.detect(in: snapshot.command) != nil
            && !liveTmuxSessionNames.contains(tmuxSessionName)
        return SessionRestorationPlan(
            tmuxSessionName: tmuxSessionName,
            status: SessionLifecyclePolicy.restoredStatus(snapshotStatus: snapshot.status),
            needsRecovery: missingAgentBackend || SessionLifecyclePolicy.shouldMarkForRecovery(
                status: snapshot.status,
                tmuxSessionName: tmuxSessionName,
                liveTmuxSessionNames: liveTmuxSessionNames
            )
        )
    }
}
