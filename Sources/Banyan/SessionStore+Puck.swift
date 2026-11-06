import BanyanCore
import Foundation
import AppKit
import SwiftUI

extension SessionStore {
    // MARK: - Puck sessions

    /// Creates a daemon session and adds it to the working set once `puckd`
    /// has it. A first prompt starts the first turn; if that fails the session
    /// still exists and the error says so.
    @discardableResult
    func createPuckSession(
        binding: PuckSessionBinding,
        cwd proposedCWD: String?,
        id proposedID: String? = nil,
        title: String? = nil,
        titleURL: String? = nil,
        parentSessionID: String? = nil,
        tone: SessionTone = .blue,
        prompt: String? = nil,
        select: Bool = true,
        placementSessionID: String? = nil
    ) async throws -> PuckSession {
        let focusedSessionID = placementSessionID ?? selection.selectedSessionID
        let cwd = WorkingDirectoryPolicy.resolve(
            proposedDirectory: proposedCWD,
            currentDirectory: currentDirectory,
            homeDirectory: homeDirectory
        )
        let id = SessionInputPolicy.normalizedOptionalText(proposedID) ?? UUID().uuidString.lowercased()
        guard !sessions.contains(where: { $0.id == id }), !pendingPuckCreationIDs.contains(id),
              !agentAdmission.running.contains(id), agentAdmission.position(of: id) == nil else {
            throw ControlError.conflict(code: "session_exists", message: "session '\(id)' already exists")
        }
        let daemon = puckDaemon
        pendingPuckCreationIDs.insert(id)
        defer { pendingPuckCreationIDs.remove(id) }
        let summary = try await Task.detached(priority: .userInitiated) {
            try daemon.create(
                id: id,
                provider: binding.provider,
                account: binding.account,
                model: binding.model,
                workspace: cwd
            )
        }.value
        notePuckDaemonReachable(true)
        // Row IDs must stay unique, and the daemon answers with its own.
        guard !sessions.contains(where: { $0.id == summary.id }),
              !agentAdmission.running.contains(summary.id), agentAdmission.position(of: summary.id) == nil,
              !codexThreads.reserves(sessionID: summary.id) else {
            throw ControlError.conflict(code: "session_exists", message: "session '\(summary.id)' already exists")
        }
        let explicitTitle = SessionInputPolicy.normalizedOptionalText(title)
        let session = PuckSession(
            id: summary.id,
            binding: PuckSessionBinding(summary: summary),
            title: explicitTitle ?? PathDisplayName.make(path: summary.cwd, homeDirectory: homeDirectory),
            titleURL: SessionInputPolicy.normalizedTitleURL(titleURL),
            isTitlePinned: explicitTitle != nil,
            cwd: summary.cwd,
            status: PuckSessionStatusPolicy.status(for: summary),
            tone: tone,
            parentSessionID: SessionInputPolicy.normalizedOptionalText(parentSessionID),
            daemon: daemon,
            telemetry: telemetry,
            host: host,
            githubReferenceCache: githubReferenceCache
        )
        attach(session)
        puckRowEpoch += 1
        insertCreatedSession(session, focusedSessionID: focusedSessionID)
        noteBackgroundPuckSessionOpened(session.id)
        session.apply(summary: summary)
        if select {
            expandAncestors(of: session.id)
            selectedSessionID = session.id
            refreshSelectedContextInfo(force: true)
        }
        saveSessions()
        if let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do {
                try await session.startTurn(prompt)
            } catch {
                throw PuckTurnError(sessionID: session.id, message: error.localizedDescription)
            }
        }
        return session
    }

    /// Synchronous CLI/TUI delivery never leaves a prompt waiting behind a
    /// transport that can time out. UI sends keep their cancellable FIFO queue.
    func startPuckTurnImmediately(id: String, prompt: String, expiresAt: Date,
                                  authorization: (() throws -> Void)? = nil,
                                  willSubmit: (() throws -> Void)? = nil,
                                  mayDispatch: @escaping @Sendable () -> Bool = { true }) async throws -> PuckSession {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ControlError.badRequest("Turn prompt must not be empty; nothing was queued")
        }
        func validateOwnership() throws {
            guard !sessions.contains(where: { $0.id == id && !($0 is PuckSession) }),
                  !(admissionTerminals[id] != nil && agentAdmission.running.contains(id)),
                  !codexThreads.reserves(sessionID: id), !pendingPuckCreationIDs.contains(id) else {
                throw ControlError.conflict(code: "session_exists", message: "session '\(id)' belongs to another runtime; nothing was queued")
            }
        }
        try validateOwnership()
        try authorization?()
        let session: PuckSession
        if let existing = admissionPuckSessions[id] { session = existing }
        else {
            let daemon = puckDaemon
            let summary = try await Task.detached(priority: .utility) { try daemon.get(id) }.value
            try validateOwnership()
            session = adoptPuckSession(summary)
        }
        try authorization?()
        guard Date() < expiresAt else { throw ControlError.conflict(code: "request_expired", message: "Turn request expired; nothing was queued") }
        guard !session.admissionTurnInFlight, session.turnUnavailableReason == nil else {
            throw ControlError.conflict(code: "turn_busy", message: session.turnUnavailableReason ?? "A turn is already starting")
        }
        guard agentAdmission.acquireImmediately(id) else {
            throw ControlError.conflict(code: "agent_capacity_busy", message: "All \(maximumConcurrentAgents) agent slots are in use. Nothing was queued; retry later or send from the app's visible queue.")
        }
        // Sending a turn here is an explicit choice to work in this session.
        if !sessions.contains(where: { $0 === session }) {
            sessions.append(session)
            puckRowEpoch += 1
        }
        noteBackgroundPuckSessionOpened(id)
        session.reopen()
        // No suspension point lies between reservation and startTurn entering
        // its in-flight guard. Errors release only a definitively unused slot.
        try await session.startTurn(prompt, authorization: authorization, willSubmit: willSubmit, mayDispatch: mayDispatch)
        return session
    }

    /// Watch events carry turn and ask changes. Empty new sessions emit nothing,
    /// so a sparse catalog reconciliation uses the existing adaptive supervisor
    /// (one minute at the desk, five minutes in the background).
    var puckCatalogInterval: TimeInterval {
        supervisorActivityLevel == .active ? 60 : 300
    }

    func syncPuckSessions() {
        guard !isPuckSyncRunning else { return }
        // The watch owns reconnect attempts; supervisor ticks must not add a
        // second recovery poll while its connection is being established.
        if puckWatchTask != nil && !isPuckWatchConnected { return }
        if puckObservation != nil, let lastPuckSnapshotAt,
           Date().timeIntervalSince(lastPuckSnapshotAt) < puckCatalogInterval { return }
        isPuckSyncRunning = true
        let daemon = puckDaemon
        let epoch = puckRowEpoch
        Task.detached(priority: .utility) { [weak self] in
            let summaries = try? daemon.list()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isPuckSyncRunning = false
                // An unreachable daemon says nothing about its sessions; keep
                // what the rows last showed.
                if let summaries {
                    self.applyPuckSummaries(summaries, closingMissing: epoch == self.puckRowEpoch)
                }
                // The listing may have started or finished a turn, or found the
                // daemon gone or back; the timer's cadence depends on both.
                self.notePuckDaemonReachable(summaries != nil)
            }
        }
    }

    /// Records whether `puckd` answered, and re-evaluates the supervisor
    /// cadence that carries its listing.
    private func notePuckDaemonReachable(_ reachable: Bool) {
        isPuckDaemonReachable = reachable
        if reachable { lastPuckSnapshotAt = Date() }
        if supervisorTimer != nil {
            rescheduleSupervisor()
        }
    }

    /// One socket watches all sessions and reports this frontend's activity.
    /// Reconnect backoff applies only while disconnected; live state is pushed.
    func startPuckObservation() {
        guard puckWatchTask == nil else { return }
        puckWatchGeneration += 1
        let generation = puckWatchGeneration
        let monitor = PuckPresenceMonitor()
        puckPresenceMonitor = monitor
        monitor.start()
        attentionNotifier.onOpenPuckSession = { [weak self] id in self?.openPuckSession(id: id) }
        puckWatchTask = Task { [weak self] in
            var delay: UInt64 = 1
            while !Task.isCancelled {
                guard self?.puckWatchGeneration == generation else { return }
                guard let daemon = self?.puckDaemon else { return }
                let observation = daemon.watch()
                self?.puckObservation = observation
                monitor.observe(observation)
                do {
                    for try await update in observation.updates {
                        guard let self, self.puckWatchGeneration == generation, !Task.isCancelled else { break }
                        delay = 1
                        switch update {
                        case .snapshot(let summaries):
                            self.isPuckWatchConnected = true
                            // A watch snapshot can predate a local create that
                            // completed during its listing. Only the epoch-checked
                            // catalog reconciliation proves a row is missing.
                            self.applyPuckSummaries(summaries, closingMissing: false)
                            self.notePuckDaemonReachable(true)
                        case .event(let id, let event):
                            self.routePuckWatchEvent(id: id, event: event)
                        }
                    }
                } catch {
                    // Keep the last durable rows while puckd is unavailable.
                }
                observation.cancel()
                monitor.observe(nil)
                guard self?.puckWatchGeneration == generation else { return }
                self?.puckObservation = nil
                self?.isPuckWatchConnected = false
                self?.notePuckDaemonReachable(false)
                do { try await Task.sleep(nanoseconds: delay * 1_000_000_000) }
                catch { return }
                delay = min(delay * 2, 30)
            }
        }
    }

    func stopPuckObservation() {
        puckWatchGeneration += 1
        puckWatchTask?.cancel()
        puckWatchTask = nil
        puckObservation?.cancel()
        puckObservation = nil
        isPuckWatchConnected = false
        puckPresenceMonitor?.stop()
        puckPresenceMonitor = nil
    }

    /// `closingMissing` is false for a listing that may predate a row Banyan
    /// added since, which would otherwise read as the daemon dropping it.
    ///
    /// A listing updates the rows Banyan already tracks, and never adds one:
    /// the sidebar is the user's working set, and the daemon also holds
    /// sessions other frontends and background tasks started. Those stay in
    /// `backgroundPuckSummaries` until the user opens one.
    func applyPuckSummaries(_ summaries: [PuckSessionSummary], closingMissing: Bool = true) {
        let summariesByID = Dictionary(summaries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var didChangeStructure = false
        // Retain accounting for hidden/removed busy rows. Transcript following
        // can stop, while the one dashboard watch still receives completion.
        for session in admissionPuckSessions.values {
            if let summary = summariesByID[session.id] {
                session.apply(summary: summary)
            } else if closingMissing, !session.admissionTurnInFlight {
                agentAdmission.release(session.id)
                guard session.status != .closed else { continue }
                // The daemon answered without it, so there is nothing left to
                // follow or reopen.
                session.closeBackingSession()
                didChangeStructure = true
            }
        }
        updateBackgroundPuckSummaries(summaries)
        if didChangeStructure {
            saveSessions()
        }
    }

    /// Opens a `banyan://puck/<id>` link. Following a link is an explicit ask
    /// to see that session, so it also brings back a closed or removed row, or
    /// adds a background session to the working set. A session the last
    /// listing described opens at once; otherwise the daemon is asked directly
    /// instead of waiting for the next listing.
    func openPuckSession(id: String) {
        sidebarMode = .sessions
        if let session = sessions.first(where: { $0.id == id }) {
            noteBackgroundPuckSessionOpened(id)
            if session.status == .closed {
                try? respawn(id: id)
            } else {
                userSelect(id: id)
            }
            return
        }
        if let summary = backgroundPuckSummaries.first(where: { $0.id == id }) {
            openPuckSession(summary)
            return
        }
        let daemon = puckDaemon
        Task { [weak self] in
            do {
                let summary = try await Task.detached(priority: .userInitiated) {
                    try daemon.get(id)
                }.value
                guard let self else { return }
                if self.sessions.contains(where: { $0.id == id }) {
                    self.userSelect(id: id)
                } else {
                    self.openPuckSession(summary)
                }
            } catch {
                self?.puckSessionError = "Could not open puck session \(id): \(error.localizedDescription)"
            }
        }
    }

    /// Adds a daemon session the user chose to the working set, as a row in
    /// the project its workspace belongs to.
    ///
    /// A row removed earlier in this run is still the object admission
    /// accounts with, so it comes back rather than a duplicate. Returns `nil`
    /// when another runtime's row already has the ID.
    @discardableResult
    func openPuckSession(_ summary: PuckSessionSummary, select: Bool = true) -> PuckSession? {
        let session: PuckSession
        if let existing = sessions.first(where: { $0.id == summary.id }) {
            guard let puck = existing as? PuckSession else { return nil }
            session = puck
        } else if let retained = admissionPuckSessions[summary.id] {
            session = retained
            sessions.append(retained)
            puckRowEpoch += 1
        } else {
            session = adoptPuckSession(summary)
        }
        // A tracked row's own summary is at least as new as the listing this
        // one came from, so reopening restores the status it last reported.
        if session.status == .closed { session.reopen() }
        noteBackgroundPuckSessionOpened(summary.id)
        saveSessions()
        if select { userSelect(id: summary.id) }
        return session
    }

    /// Adds a row for a daemon session Banyan did not start, such as one
    /// created from Slack. Only explicit opens and turns call this.
    @discardableResult
    private func adoptPuckSession(_ summary: PuckSessionSummary) -> PuckSession {
        let status = PuckSessionStatusPolicy.status(for: summary)
        let session = PuckSession(
            id: summary.id,
            binding: PuckSessionBinding(summary: summary),
            title: PathDisplayName.make(path: summary.cwd, homeDirectory: homeDirectory),
            cwd: summary.cwd,
            status: status,
            tone: PuckSessionStatusPolicy.tone(for: status),
            daemon: puckDaemon,
            telemetry: telemetry,
            host: host,
            githubReferenceCache: githubReferenceCache
        )
        attach(session)
        puckRowEpoch += 1
        sessions.append(session)
        session.apply(summary: summary)
        return session
    }
}
