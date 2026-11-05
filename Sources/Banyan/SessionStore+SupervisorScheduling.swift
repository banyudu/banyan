import BanyanCore
import Foundation
import AppKit
import SwiftUI

extension SessionStore {
    /// App-owned startup, independent of any window. Restore before accepting
    /// control requests or supervising sessions, and never repeat launch work.
    func startRuntimeIfNeeded() {
        guard !didStartRuntime else { return }
        didStartRuntime = true
        startDeepSuspendPressureMonitor()
        loadPersistedSessionsIfNeeded()
        autoRecoverRestoredAgentSessionsIfNeeded()
        spawnDefaultSessionIfEmpty()
        refreshImportedHistoryIfNeeded()
        startControlServer()
        Task { [weak self] in await self?.codexRemote.restoreObservation() }
        startSupervisor()
    }

    func startControlServer() {
        guard controlServer == nil else { return }
        let server = makeControlServer(self, host)
        server.start()
        controlServer = server
    }

    func startSupervisor() {
        installSupervisorLifecycleObserversIfNeeded()
        rescheduleBranchRefreshTimer()
        installCodexTitleWatcherIfNeeded()
        guard !didStartSupervisor else { return }
        didStartSupervisor = true
        rescheduleSupervisor(runImmediately: true)
        startPuckObservation()
    }

    /// How visible the app is, which decides how fresh its polled state has to be.
    ///
    /// `NSApp.isActive` alone cannot tell "on screen behind another app" apart from
    /// "hidden, miniaturized, or fully covered", and only the second is free to
    /// throttle. `NSApplication.occlusionState` is the app-wide roll-up macOS itself
    /// uses to decide whether an app is a candidate for App Nap: `.visible` means at
    /// least one window is on screen and not completely obscured.
    ///
    /// Banyan cannot ask to be napped — no API grants that — and a napped app would
    /// still spawn every subprocess its timers ask for, just later. So the app reads
    /// the same signal the OS reads and throttles itself.
    var supervisorActivityLevel: SupervisorActivityLevel {
        // `NSApp` is nil outside a GUI process — a store under test, for one —
        // and reading through the implicitly unwrapped optional traps. Not
        // being able to ask is not the same as being hidden: the middle
        // cadence is the honest answer, and the app itself always has an
        // `NSApplication` by the time a store exists.
        guard let app = NSApp else { return .backgroundVisible }
        if app.isActive { return .active }
        if app.isHidden { return .hidden }
        return app.occlusionState.contains(.visible) ? .backgroundVisible : .hidden
    }

    /// Adaptive cadence for the supervisor poll. Each tick batches pane metadata,
    /// and due observations share one process snapshot and cached pane captures.
    /// Stable sessions are deferred independently, and when every session is
    /// deferred the timer sleeps until the next one is due. The base interval is
    /// still adaptive to foreground/background, battery, thermal state, and
    /// session count so active work remains responsive.
    var supervisorBaseInterval: TimeInterval {
        let startedSessions = sessions.reduce(into: 0) { count, session in
            guard session.status != .closed else { return }
            if let terminal = session as? TerminalSession {
                guard !terminal.isFrozen, !terminal.isDeepSuspended else { return }
                if SessionLifecyclePolicy.participatesInSupervisorTick(
                    isProcessStarted: terminal.isProcessStarted,
                    isRestored: terminal.isRestored,
                    isSuspended: terminal.isSuspended
                ) { count += 1 }
            } else if session.isProcessStarted {
                count += 1
            }
        }
        let activeSessions = sessions.reduce(into: 0) { count, session in
            guard session.status != .closed else { return }
            // A running puck turn can finish between listings just as a terminal
            // agent can between inspections. It adds no inspection cost, so it
            // counts as active work without counting toward the fleet size.
            let isObserved: Bool
            if let terminal = session as? TerminalSession {
                guard !terminal.isFrozen, !terminal.isDeepSuspended else { return }
                // Restored/unattached panes are still inspected. Excluding them
                // here gave a hidden executing fleet the 300s idle cadence.
                isObserved = SessionLifecyclePolicy.participatesInSupervisorTick(
                    isProcessStarted: terminal.isProcessStarted,
                    isRestored: terminal.isRestored,
                    isSuspended: terminal.isSuspended
                )
            } else {
                isObserved = session is PuckSession ? puckObservation == nil && !session.isSuspended : session.isProcessStarted
            }
            guard isObserved else { return }
            if !session.status.isCodingAgentIdle && ![.completed, .failed].contains(session.status) {
                count += 1
            }
        }
        return SessionSupervisorCadencePolicy.interval(
            activityLevel: supervisorActivityLevel,
            startedSessionCount: startedSessions,
            activeSessionCount: activeSessions,
            isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalState: supervisorThermalState
        )
    }

    private var supervisorThermalState: SupervisorThermalState {
        switch ProcessInfo.processInfo.thermalState {
        case .fair:
            return .fair
        case .serious:
            return .serious
        case .critical:
            return .critical
        default:
            return .nominal
        }
    }

    private var supervisorActivityInterval: TimeInterval {
        SessionSupervisorCadencePolicy.activityInterval(
            activityLevel: supervisorActivityLevel,
            isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalState: supervisorThermalState
        )
    }

    var supervisorInterval: TimeInterval {
        let baseInterval = supervisorBaseInterval
        var terminalInterval = terminalSupervisorInterval(baseInterval: baseInterval)
        if autoFreezeAgents && terminalSessions.contains(where: { $0.status != .closed && !$0.isSuspended && !$0.isFrozen }) {
            terminalInterval = min(terminalInterval, AgentInactivityPolicy.probeInterval(threshold: agentFreezeThreshold))
        }
        if terminalSessions.contains(where: \.isFrozen) {
            terminalInterval = min(terminalInterval, 15)
        }
        if terminalSessions.contains(where: { $0.status != .closed && !$0.isDeepSuspended
            && $0.agentProvider.map { deepSuspendPolicy(for: $0).automatic } == true }) {
            terminalInterval = min(terminalInterval, isUnderMemoryPressure ? 15 : 60)
        }
        if puckObservation != nil { return min(terminalInterval, puckCatalogInterval) }
        return isPuckDaemonReachable ? min(terminalInterval, baseInterval) : terminalInterval
    }

    func isSelectedAttached(_ session: BanyanSession) -> Bool {
        session.id == selectedSessionID
            && (session as? TerminalSession)?.loadedTerminalView?.process.running == true
    }

    /// Back off expensive observations independently, but retain a bounded
    /// batched activity probe for unattached/evicted panes without PTY callbacks.
    private func terminalSupervisorInterval(baseInterval: TimeInterval) -> TimeInterval {
        let participatingSessions = terminalSessions.filter {
            $0.status != .closed && !$0.isFrozen && !$0.isDeepSuspended
                && SessionLifecyclePolicy.participatesInSupervisorTick(
                    isProcessStarted: $0.isProcessStarted,
                    isRestored: $0.isRestored,
                    isSuspended: $0.isSuspended
                )
        }
        guard !participatingSessions.isEmpty else { return baseInterval }

        let now = Date()
        return participatingSessions.map { session in
            (supervisorObservationStates[session.id] ?? .init()).nextProbeInterval(
                baseInterval: baseInterval,
                status: session.status,
                isSelectedAttached: isSelectedAttached(session),
                at: now
            )
        }.min() ?? baseInterval
    }

    /// Re-evaluate the adaptive cadence and reinstall the timer only when it
    /// actually changed. `runImmediately` fires a tick now (used on launch and when
    /// the app regains focus, so the sidebar refreshes without waiting a full cycle).
    func rescheduleSupervisor(runImmediately: Bool = false) {
        guard didStartSupervisor else { return }
        if runImmediately {
            runSupervisorTick(force: true)
        }

        // A tick owns the next deadline until it completes. Timer/lifecycle
        // requests during it are coalesced into the per-session due state.
        let now = Date()
        guard let dueAt = supervisorTickSchedule.replacementFire(
            at: now,
            scheduledFire: supervisorTimer == nil ? nil : supervisorTimerDueAt,
            activityPending: !pendingSupervisorActivityIDs.isEmpty,
            activityInterval: pendingSupervisorSignalIDs.isEmpty ? supervisorActivityInterval : 2,
            interval: supervisorInterval
        ) else { return }
        supervisorTimer?.invalidate()
        supervisorTimerDueAt = dueAt
        let interval = max(0.01, dueAt.timeIntervalSince(now))
        supervisorScheduledInterval = interval
        let generation = UUID()
        supervisorTimerGeneration = generation
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard self?.supervisorTimerGeneration == generation else { return }
                self?.supervisorTimerFired()
            }
        }
        // Let macOS coalesce these wakeups with other timers to cut energy use.
        timer.tolerance = interval * 0.25
        RunLoop.main.add(timer, forMode: .common)
        supervisorTimer = timer
    }

    func deepSuspendPolicyDidChange() {
        if didStartSupervisor { rescheduleSupervisor() }
    }

    private func supervisorTimerFired() {
        supervisorTimer = nil
        runSupervisorTick()
        syncPuckSessions()
        runAutoFreezePassIfNeeded()
        runDeepSuspendPass(underPressure: isUnderMemoryPressure)
        reconcileFrozenAgents()
        sweepSuspendedSessionLivenessIfNeeded()
        // Focus, thermal, power, or session count may have changed since the timer
        // was installed; adopt the new cadence for the next fire.
        rescheduleSupervisor()
    }

    private func installSupervisorLifecycleObserversIfNeeded() {
        guard supervisorLifecycleObservers.isEmpty else { return }
        let center = NotificationCenter.default
        let onActive = center.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.lastObservedActivityLevel = .active
                self?.rescheduleSupervisor(runImmediately: true)
                self?.syncPuckSessions()
                self?.rescheduleBranchRefreshTimer()
                self?.refreshBranchContextsIfNeeded(force: true)
                self?.refreshSelectedLinearIssueStatus()
                // Safety net for config edits the file watcher may have missed
                // (e.g. while suspended): three small YAML reads, no-ops skipped.
                self?.reloadLaunchConfiguration()
            }
        }
        let onResign = center.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyActivityLevelChange() }
        }
        // Hiding, miniaturizing, or burying every window behind another app changes
        // what the user can see without changing which app is frontmost, and that is
        // the line the cadence policy throttles on.
        let onHide = center.addObserver(
            forName: NSApplication.didHideNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyActivityLevelChange() }
        }
        let onUnhide = center.addObserver(
            forName: NSApplication.didUnhideNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyActivityLevelChange() }
        }
        let onOcclusion = center.addObserver(
            forName: NSApplication.didChangeOcclusionStateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyActivityLevelChange() }
        }
        let onThermal = center.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rescheduleSupervisor() }
        }
        let onPower = center.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rescheduleSupervisor() }
        }
        let onTerminate = center.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.prepareForAgentFreezeShutdown() }
        }
        supervisorLifecycleObservers = [
            onActive, onResign, onHide, onUnhide, onOcclusion, onThermal, onPower,
            onTerminate,
        ]
    }

    /// Re-times everything that depends on how visible the app is. Coming back from
    /// `.hidden` runs an immediate forced tick and forces the chrome refreshes the
    /// throttled path skipped, so the first frame the user sees is re-synced rather
    /// than showing whatever was true when the window was covered.
    private func applyActivityLevelChange() {
        let level = supervisorActivityLevel
        let becameVisible = level != .hidden && lastObservedActivityLevel == .hidden
        lastObservedActivityLevel = level
        rescheduleSupervisor(runImmediately: becameVisible)
        rescheduleBranchRefreshTimer()
        guard becameVisible else { return }
        refreshBranchContextsIfNeeded(force: true)
        refreshSelectedLinearIssueStatus()
    }
}
