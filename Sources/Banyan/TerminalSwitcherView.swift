import BanyanCore
import QuartzCore
import SwiftUI
import SwiftTerm

/// Creates terminal views only when visited, then keeps their independently
/// backed layers attached and switches between them with visibility toggles.
struct TerminalSwitcherView: NSViewRepresentable {
    let sessions: [BanyanSession]
    let selectedSessionID: String?
    let theme: TerminalTheme
    let fontFamily: String
    let fontSize: Double
    let focusRequestID: UUID
    var switchRequestedAt: DispatchTime?
    var selectionChangedAt: DispatchTime?
    var clickAt: DispatchTime?
    var selection: SessionSelection?

    func makeNSView(context: Context) -> TerminalSwitcherContainer {
        let container = TerminalSwitcherContainer()
        selection?.switcher = container
        return container
    }

    func updateNSView(_ nsView: TerminalSwitcherContainer, context: Context) {
        nsView.update(
            switchRequestedAt: switchRequestedAt,
            selectionChangedAt: selectionChangedAt,
            clickAt: clickAt,
            sessions: sessions,
            selectedSessionID: selectedSessionID,
            theme: theme,
            fontFamily: fontFamily,
            fontSize: fontSize,
            focusRequestID: focusRequestID,
            onUserSubmittedInput: { session, buffer in
                session.noteUserSubmittedInput(buffer)
            },
            onTerminalReady: { session in
                session.telemetry.noteSessionTerminalReady(sessionID: session.id)
                session.renderRestoredMessageIfNeeded(
                    theme: theme, fontFamily: fontFamily, fontSize: fontSize
                )
                guard session.status != .closed,
                      !session.isImportedHistory,
                      !session.needsManualAttach else {
                    return
                }
                session.start()
                session.refreshTerminalClient(immediately: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    session.refreshTerminalClient()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.50) {
                    session.recoverBlankTerminalClientIfNeeded()
                }
            }
        )
    }
}

final class TerminalSwitcherContainer: NSView {
    private struct DeferredProjectSwitch {
        let token = UUID()
        let sourceID: String
        let targetID: String
        let sourceAutoresizingMask: NSView.AutoresizingMask
        let selectionChangedAt: DispatchTime?
        let clickAt: DispatchTime?
        var isPrepared = false
    }

    private var containers: [String: TerminalContainerView] = [:]
    private var initializedSessions: Set<String> = []
    private var telemetry: PerformanceTelemetry?
    private var activeSessionID: String?
    private var lastFocusRequestID: UUID?
    private var pendingAfterPaint: (sessionID: String, action: () -> Void)?
    private var windowLifecycleObservers: [NSObjectProtocol] = []
    private var projectGroupBySessionID: [String: String] = [:]
    private var deferredProjectSwitch: DeferredProjectSwitch?

    override init(frame: NSRect) {
        super.init(frame: frame)
        installWindowLifecycleObservers()
    }

    deinit {
        for observer in windowLifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Called directly from `SessionSelection.didSet` to swap cached views
    /// without waiting for SwiftUI's view update pipeline.
    @discardableResult
    func switchImmediately(
        to newID: String?,
        selectionChangedAt: DispatchTime?,
        clickAt: DispatchTime?,
        afterPaint: (() -> Void)? = nil
    ) -> Bool {
        if let deferred = deferredProjectSwitch {
            if deferred.targetID == newID {
                return true
            }
            cancelDeferredProjectSwitch()
            if deferred.sourceID == newID {
                return true
            }
        }
        guard activeSessionID != newID else { return false }
        let oldID = activeSessionID
        let sourceGroup = oldID.flatMap { projectGroupBySessionID[$0] }
        let targetGroup = newID.flatMap { projectGroupBySessionID[$0] }
        let crossesProjectBoundary = sourceGroup != nil && targetGroup != nil && sourceGroup != targetGroup
        if crossesProjectBoundary,
           let oldID,
           let newID,
           let sourceContainer = containers[oldID] {
            // Commit the selection's contextual panel before the target becomes
            // visible. Keep the current container at its existing geometry until
            // the hidden target has finished tmux's resize redraw.
            let sourceAutoresizingMask = sourceContainer.autoresizingMask
            sourceContainer.autoresizingMask = []
            deferredProjectSwitch = DeferredProjectSwitch(
                sourceID: oldID,
                targetID: newID,
                sourceAutoresizingMask: sourceAutoresizingMask,
                selectionChangedAt: selectionChangedAt,
                clickAt: clickAt
            )
            return true
        }
        if let newID, let afterPaint {
            pendingAfterPaint = (newID, afterPaint)
        } else if newID == nil {
            pendingAfterPaint = nil
            afterPaint?()
        }
        let isRevisit = newID.map { containers[$0] != nil } ?? false
        if let clickAt {
            telemetry?.recordDuration(
                "switcher.from_click",
                durationMS: PerformanceTelemetry.elapsedMS(since: clickAt),
                sessionID: newID,
                detail: isRevisit ? "revisit" : "first"
            )
        }

        // A first visit has no cached terminal to reveal yet. Leave the current
        // terminal attached until SwiftUI supplies the selected session below.
        guard newID == nil || isRevisit else { return false }

        let synchronousWorkStartedAt = DispatchTime.now()
        hideActiveContainer()
        recordSynchronousStage("hide", since: synchronousWorkStartedAt, sessionID: newID)
        activeSessionID = newID
        if let newID, let newContainer = containers[newID] {
            if let startedAt = clickAt ?? selectionChangedAt {
                newContainer.measureNextSwitchPaint(
                    startedAt: startedAt,
                    sessionID: newID,
                    telemetry: telemetry,
                    afterPaint: takeAfterPaint(for: newID)
                )
            }
            attach(newContainer)
            recordSynchronousStage("reveal", since: synchronousWorkStartedAt, sessionID: newID)
            window?.makeFirstResponder(newContainer.terminalView)
            recordSynchronousStage("focus", since: synchronousWorkStartedAt, sessionID: newID)
        }

        // The state change above is instant, but the frame only paints once the
        // main thread reaches its next display cycle. Measure that separately —
        // a blocked main thread is invisible to the state-change timestamp.
        if let startedAt = clickAt ?? selectionChangedAt {
            let sessionID = newID
            CATransaction.begin()
            CATransaction.setCompletionBlock {
                self.telemetry?.recordDuration(
                    "switcher.frame_painted",
                    durationMS: PerformanceTelemetry.elapsedMS(since: startedAt),
                    sessionID: sessionID,
                    detail: isRevisit ? "revisit" : "first"
                )
            }
            CATransaction.commit()

            DispatchQueue.main.async {
                self.telemetry?.recordDuration(
                    "main_thread.free_after_switch",
                    durationMS: PerformanceTelemetry.elapsedMS(since: startedAt),
                    sessionID: sessionID
                )
            }
        }
        return false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        switchRequestedAt: DispatchTime?,
        selectionChangedAt: DispatchTime?,
        clickAt: DispatchTime?,
        sessions: [BanyanSession],
        selectedSessionID: String?,
        theme: TerminalTheme,
        fontFamily: String,
        fontSize: Double,
        focusRequestID: UUID,
        onUserSubmittedInput: @escaping (BanyanSession, String?) -> Void,
        onTerminalReady: @escaping (BanyanSession) -> Void
    ) {
        let liveSessions = sessions.filter { !$0.isImportedHistory && $0.status != .closed }
        projectGroupBySessionID = Dictionary(
            liveSessions.map { ($0.id, $0.projectGroupID) },
            uniquingKeysWith: { first, _ in first }
        )
        if let selectedSessionID,
           let selectedSession = liveSessions.first(where: { $0.id == selectedSessionID }) {
            telemetry = selectedSession.telemetry
        } else if let firstSession = liveSessions.first {
            telemetry = firstSession.telemetry
        }
        let liveIDs = Set(liveSessions.map(\.id))

        // Remove containers for sessions that no longer exist
        for (id, container) in containers where !liveIDs.contains(id) {
            container.removeFromSuperviewWithoutNeedingDisplay()
            containers.removeValue(forKey: id)
            initializedSessions.remove(id)
            if activeSessionID == id {
                activeSessionID = nil
            }
        }

        let selectedSession = selectedSessionID.flatMap { selectedID in
            liveSessions.first { $0.id == selectedID }
        }

        // Create terminal views on first selection, not merely because a session
        // appears in the sidebar. Visited terminals retain their own backing
        // layers, so revisits only toggle visibility instead of reparenting.
        if let selectedSession, containers[selectedSession.id] == nil {
            let container = TerminalContainerView(
                terminalView: selectedSession.terminalView,
                session: selectedSession,
                onUserSubmittedInput: { onUserSubmittedInput(selectedSession, $0) }
            )
            container.apply(theme: theme)
            selectedSession.apply(theme: theme, fontFamily: fontFamily, fontSize: fontSize)
            containers[selectedSession.id] = container
        }

        // Apply theme only to terminals that have actually been visited.
        for session in liveSessions {
            guard let container = containers[session.id] else { continue }
            container.apply(theme: theme)
            container.onUserSubmittedInput = { onUserSubmittedInput(session, $0) }
            session.apply(theme: theme, fontFamily: fontFamily, fontSize: fontSize)
        }

        if let deferred = deferredProjectSwitch {
            guard deferred.targetID == selectedSessionID,
                  let targetSession = selectedSession,
                  let targetContainer = containers[deferred.targetID] else {
                cancelDeferredProjectSwitch()
                // Fall through to the regular path so a rapid selection change
                // cannot leave a frozen source container on screen.
                return update(
                    switchRequestedAt: switchRequestedAt,
                    selectionChangedAt: selectionChangedAt,
                    clickAt: clickAt,
                    sessions: sessions,
                    selectedSessionID: selectedSessionID,
                    theme: theme,
                    fontFamily: fontFamily,
                    fontSize: fontSize,
                    focusRequestID: focusRequestID,
                    onUserSubmittedInput: onUserSubmittedInput,
                    onTerminalReady: onTerminalReady
                )
            }
            prepareDeferredProjectSwitch(
                deferred,
                targetContainer: targetContainer,
                targetSession: targetSession,
                onTerminalReady: onTerminalReady
            )
            return
        }

        // Switch visibility
        let selectionChanged = activeSessionID != selectedSessionID
        if selectionChanged {
            let isRevisit = selectedSessionID.map { initializedSessions.contains($0) } ?? false
            if let selAt = selectionChangedAt {
                telemetry?.recordDuration(
                    "switcher.from_selection",
                    durationMS: PerformanceTelemetry.elapsedMS(since: selAt),
                    sessionID: selectedSessionID,
                    detail: isRevisit ? "revisit" : "first"
                )
            }
            if let clickAt {
                telemetry?.recordDuration(
                    "switcher.from_click",
                    durationMS: PerformanceTelemetry.elapsedMS(since: clickAt),
                    sessionID: selectedSessionID,
                    detail: isRevisit ? "revisit" : "first"
                )
            }
            if let switchAt = switchRequestedAt {
                telemetry?.recordDuration(
                    "switcher.switch_visible",
                    durationMS: PerformanceTelemetry.elapsedMS(since: switchAt),
                    sessionID: selectedSessionID,
                    detail: isRevisit ? "revisit" : "first"
                )
            }
            hideActiveContainer()
            activeSessionID = selectedSessionID
        }

        // Closed and imported-history selections intentionally have no terminal
        // container. Their detail UI is rendered by SwiftUI after SessionStore's
        // selection catches up, so there will never be a terminal paint from which
        // to run the deferred forwarder. Forward on the next main-loop turn instead
        // (publishing synchronously from updateNSView would mutate view state while
        // SwiftUI is updating it).
        if let selectedSessionID,
           selectedSession == nil,
           let afterPaint = takeAfterPaint(for: selectedSessionID) {
            DispatchQueue.main.async(execute: afterPaint)
        }

        if let newID = selectedSessionID, let newContainer = containers[newID] {
            if newContainer.superview !== self {
                if selectionChanged, let startedAt = clickAt ?? selectionChangedAt ?? switchRequestedAt {
                    newContainer.measureNextSwitchPaint(
                        startedAt: startedAt,
                        sessionID: newID,
                        telemetry: telemetry,
                        afterPaint: takeAfterPaint(for: newID)
                    )
                }
                attach(newContainer)
            }

            // First-time initialization for this session
            if !initializedSessions.contains(newID),
               let session = selectedSession {
                initializedSessions.insert(newID)
                newContainer.syncTerminalFrameIfNeeded(markNeedsDisplay: true)
                newContainer.performWhenTerminalReady(for: session.terminalView) {
                    onTerminalReady(session)
                }
            }

            // Focus on selection change or explicit focus request
            if selectionChanged || lastFocusRequestID != focusRequestID {
                lastFocusRequestID = focusRequestID
                newContainer.focusTerminalWhenReady()
            }
        }
    }

    /// Move a target into the current (already-reserved) terminal frame while it
    /// is hidden. The source stays frozen until tmux has completed the resize
    /// redraw, so a contextual issue panel never makes an on-screen terminal
    /// briefly render at two different widths.
    private func prepareDeferredProjectSwitch(
        _ deferred: DeferredProjectSwitch,
        targetContainer: TerminalContainerView,
        targetSession: BanyanSession,
        onTerminalReady: @escaping (BanyanSession) -> Void
    ) {
        guard !deferred.isPrepared else { return }
        var prepared = deferred
        prepared.isPrepared = true
        deferredProjectSwitch = prepared

        let terminal = targetContainer.terminalView as? DetectingLocalProcessTerminalView
        terminal?.synchronizeForProjectSwitch { [weak self] in
            self?.completeDeferredProjectSwitch(token: deferred.token)
        }

        attachHidden(targetContainer)
        targetContainer.needsLayout = true
        targetContainer.layoutSubtreeIfNeeded()
        targetContainer.syncTerminalFrameIfNeeded(markNeedsDisplay: true)

        if !initializedSessions.contains(deferred.targetID) {
            initializedSessions.insert(deferred.targetID)
            targetContainer.performWhenTerminalReady(for: targetSession.terminalView) {
                onTerminalReady(targetSession)
            }
        }

        // Every Banyan terminal currently uses DetectingLocalProcessTerminalView,
        // but retain a safe completion path if a future terminal implementation
        // does not need the synchronization hook.
        if terminal == nil {
            DispatchQueue.main.async { [weak self] in
                self?.completeDeferredProjectSwitch(token: deferred.token)
            }
        }
    }

    private func completeDeferredProjectSwitch(token: UUID) {
        guard let deferred = deferredProjectSwitch,
              deferred.token == token,
              let targetContainer = containers[deferred.targetID] else {
            return
        }

        deferredProjectSwitch = nil
        hideFrozenSource(for: deferred)
        activeSessionID = deferred.targetID

        if let startedAt = deferred.clickAt ?? deferred.selectionChangedAt {
            targetContainer.measureNextSwitchPaint(
                startedAt: startedAt,
                sessionID: deferred.targetID,
                telemetry: telemetry
            )
            telemetry?.recordDuration(
                "switcher.project_layout_wait",
                durationMS: PerformanceTelemetry.elapsedMS(since: startedAt),
                sessionID: deferred.targetID
            )
        }

        attach(targetContainer)
        window?.makeFirstResponder(targetContainer.terminalView)
    }

    private func cancelDeferredProjectSwitch() {
        guard let deferred = deferredProjectSwitch else { return }
        deferredProjectSwitch = nil
        (containers[deferred.targetID]?.terminalView as? DetectingLocalProcessTerminalView)?
            .cancelInitialScreenSynchronization()

        if let sourceContainer = containers[deferred.sourceID] {
            sourceContainer.autoresizingMask = deferred.sourceAutoresizingMask
            sourceContainer.needsLayout = true
        }
    }

    private func hideFrozenSource(for deferred: DeferredProjectSwitch) {
        guard let sourceContainer = containers[deferred.sourceID] else { return }
        sourceContainer.isHidden = true
        sourceContainer.autoresizingMask = deferred.sourceAutoresizingMask
        sourceContainer.needsLayout = true
    }

    private func attachHidden(_ container: TerminalContainerView) {
        if container.superview !== self {
            container.translatesAutoresizingMaskIntoConstraints = true
            container.autoresizingMask = [.width, .height]
            container.frame = bounds
            container.isHidden = true
            addSubview(container)
        } else {
            container.autoresizingMask = [.width, .height]
            container.frame = bounds
            container.isHidden = true
        }
        container.needsLayout = true
    }

    private func hideActiveContainer() {
        guard let activeSessionID, let activeContainer = containers[activeSessionID] else { return }
        activeContainer.isHidden = true
    }

    private func installWindowLifecycleObservers() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSApplication.didBecomeActiveNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didChangeOcclusionStateNotification
        ]
        windowLifecycleObservers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let self,
                      notification.object as? NSWindow == nil || notification.object as? NSWindow === self.window else {
                    return
                }
                self.refreshVisibleTerminalSurface()
            }
        }
    }

    private func refreshVisibleTerminalSurface() {
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.needsLayout = true
            self.layoutSubtreeIfNeeded()
            for container in self.containers.values where !container.isHidden {
                container.refreshAfterWindowLifecycle()
            }
        }
    }

    private func attach(_ container: TerminalContainerView) {
        if container.superview !== self {
            container.translatesAutoresizingMaskIntoConstraints = true
            container.autoresizingMask = [.width, .height]
            container.frame = bounds
            container.isHidden = true
            addSubview(container)
            container.needsLayout = true
        }
        let wasHidden = container.isHidden
        container.isHidden = false

        // While a container is hidden its terminal drops every invalidation (see
        // DetectingLocalProcessTerminalView.flushCoalescedDisplayInvalidation), and
        // nothing else repaints it on a session switch — the window-lifecycle
        // observers below only fire for app/window/occlusion changes. Without this
        // the revealed terminal keeps whatever it last painted until the next byte
        // of output happens to arrive, which reads as the terminal lagging behind.
        if wasHidden {
            (container.terminalView as? DetectingLocalProcessTerminalView)?.invalidateEntireSurface()
        }
    }

    private func takeAfterPaint(for sessionID: String) -> (() -> Void)? {
        guard pendingAfterPaint?.sessionID == sessionID else { return nil }
        defer { pendingAfterPaint = nil }
        return pendingAfterPaint?.action
    }

    private func recordSynchronousStage(_ stage: String, since startedAt: DispatchTime, sessionID: String?) {
        telemetry?.recordDuration(
            "switcher.sync_\(stage)",
            durationMS: PerformanceTelemetry.elapsedMS(since: startedAt),
            sessionID: sessionID
        )
    }
}
