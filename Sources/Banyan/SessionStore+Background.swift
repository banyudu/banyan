import BanyanCore
import Foundation

extension SessionStore {
    var backgroundJournal: SessionBackgroundJournal {
        SessionBackgroundJournal(file: BanyanDataDirectory.url(for: "Banyan/presentation/background.json",
            environment: host.environment, homeDirectory: host.homeDirectory))
    }

    private var backgroundParents: [String: String] {
        Dictionary(sessions.compactMap { session in session.parentSessionID.map { (session.id, $0) } }, uniquingKeysWith: { first, _ in first })
    }

    var backgroundedSessionIDs: Set<String> {
        SessionBackgroundPolicy.hiddenIDs(roots: backgroundSessionRoots, parents: backgroundParents)
    }

    func restoreBackgroundPresentation() {
        do { backgroundSessionRoots = try backgroundJournal.load() }
        catch { backgroundPresentationError = "Saved background visibility could not be read. Conversations remain visible; their work is unchanged." }
    }

    func canHideAndKeepWorking(_ session: BanyanSession) -> Bool {
        session.status != .closed && !session.isImportedHistory && session.workflowRecoveryError == nil
            && session.workflow?.owner == "workit" && session.workflow?.state.permitsWake == true
            && !pauseCloseInFlightIDs.contains(session.id)
    }

    func hideAndKeepWorking(id: String) throws {
        guard let session = sessions.first(where: { $0.id == id }), canHideAndKeepWorking(session) else {
            throw WorkflowError.refused("Only an active managed conversation can be hidden while continuing work.")
        }
        var roots = backgroundSessionRoots; roots.insert(id)
        try backgroundJournal.save(roots)
        backgroundSessionRoots = roots
        if let selectedSessionID, backgroundedSessionIDs.contains(selectedSessionID) {
            self.selectedSessionID = visibleSessions.first?.id
        }
        sidebarMode = .work
    }

    func revealBackgroundConversation(id: String) throws {
        let roots = SessionBackgroundPolicy.revealing(id, roots: backgroundSessionRoots, parents: backgroundParents)
        guard roots != backgroundSessionRoots else { return }
        try backgroundJournal.save(roots)
        backgroundSessionRoots = roots
    }

    func confirmPendingHideAndKeepWorking() {
        guard let id = pendingCloseSession?.id else { return }
        cancelPendingClose()
        do { try hideAndKeepWorking(id: id) }
        catch { backgroundPresentationError = "The conversation could not be hidden. Its workflow remains unchanged. Check local presentation storage and retry." }
    }

    /// An active managed native thread must remain observable after selection
    /// moves away, including after restoring a hidden conversation at startup.
    func retainManagedNativeObservation(_ session: BanyanSession) {
        guard session is CodexSession else { return }
        let retained = session.workflow?.owner == "workit" && session.workflow?.state.permitsWake == true
            && session.status != .closed && !session.isSuspended && session.workflowRecoveryError == nil
        codexThreads.setRemoteObservation(sessionID: session.id, ownerID: "managed-workflow", retained: retained)
        let expected = session.workflow
        Task { [weak self, weak session] in
            guard let self, let session, session.workflow == expected else { return }
            try? await self.codexThreads.retainRemoteObservation(sessionID: session.id, retained: retained,
                ownerID: "managed-workflow", authorization: {
                    guard session.workflow?.state.permitsWake == true, session.status != .closed,
                          !session.isSuspended, session.workflowRecoveryError == nil else {
                        throw WorkflowError.refused("Managed observation is held")
                    }
                })
        }
    }
}
