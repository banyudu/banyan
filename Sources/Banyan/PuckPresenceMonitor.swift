import AppKit
import BanyanCore

/// Presence follows input and macOS lifecycle signals, never transcript output
/// or a repeating heartbeat. The daemon expires the lease after input stops.
@MainActor
final class PuckPresenceMonitor {
    private var observation: (any PuckDaemonObservation)?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var inputMonitor: Any?
    private var frontmost = false
    private var locked = false
    private var asleep = false
    private var lastActivity: Date?
    private var lastReport: Date?

    deinit {
        let tokens = observers
        let monitor = inputMonitor
        DispatchQueue.main.async {
            for (center, token) in tokens { center.removeObserver(token) }
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }

    func observe(_ observation: (any PuckDaemonObservation)?) {
        self.observation = observation
        // Reattachment is not human activity. Only replay a recent real input;
        // the socket's setup further bounds it by the configured daemon lease.
        if let lastActivity, canReportActivity,
           Date().timeIntervalSince(lastActivity) < 1 {
            observation?.reportPresence(active: true)
        } else {
            observation?.reportPresence(active: false)
        }
    }

    func start() {
        guard observers.isEmpty else { return }
        frontmost = NSApp?.isActive == true
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        observe(center, NSApplication.didBecomeActiveNotification) { $0.setFrontmost(true) }
        observe(center, NSApplication.didResignActiveNotification) { $0.setFrontmost(false) }
        observe(center, NSApplication.willTerminateNotification) { $0.stop() }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.setDisplayAsleep(true) }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.setDisplayAsleep(false) }
        observe(workspace, NSWorkspace.willSleepNotification) { $0.setDisplayAsleep(true) }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.setDisplayAsleep(false) }
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.setScreenLocked(true) }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.setScreenLocked(false) }
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel
        ]) { [weak self] event in
            self?.activity()
            return event
        }
        // Launching the foreground app is a human interaction too.
        if frontmost { activity() }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         action: @escaping @MainActor (PuckPresenceMonitor) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        }
        observers.append((center, token))
    }

    private var canReportActivity: Bool { frontmost && !locked && !asleep }

    func activity(now: Date = Date()) {
        guard canReportActivity else { return }
        lastActivity = now
        // Bound high-rate scrolling/typing; no timer keeps an idle user present.
        guard lastReport.map({ now.timeIntervalSince($0) >= 1 }) ?? true else { return }
        lastReport = now
        observation?.reportPresence(active: true)
    }

    func setFrontmost(_ value: Bool) {
        frontmost = value
        if value { activity() } else { away() }
    }

    func setScreenLocked(_ value: Bool) {
        locked = value
        if value { away() }
        // Unlock and wake alone do not prove Banyan is in use.
    }

    func setDisplayAsleep(_ value: Bool) {
        asleep = value
        if value { away() }
    }

    private func away() {
        lastActivity = nil
        lastReport = nil
        observation?.reportPresence(active: false)
    }

    func stop() {
        away()
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        inputMonitor = nil
        observation = nil
    }
}
