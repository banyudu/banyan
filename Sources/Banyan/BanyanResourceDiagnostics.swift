import AppKit
import BanyanCore
import IOKit.ps

/// Cache UI and power context through notifications; the resource monitor never
/// has to dispatch onto a possibly blocked main thread to decide to capture.
@MainActor
final class BanyanResourceDiagnostics {
    private let monitor: ResourceSpikeMonitor
    private var observers: [NSObjectProtocol] = []
    private var powerSource: CFRunLoopSource?
    private var contextProvider: (() -> (selectedSessionID: String?, startedSessionCount: Int))?

    init(host: HostRuntimeContext, telemetry: PerformanceTelemetry) {
        monitor = ResourceSpikeMonitor(
            store: ResourceSpikeCaptureStore(directoryURL: ResourceSpikeCaptureStore.defaultDirectoryURL(host: host)),
            telemetry: telemetry, environment: host.environment,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        )
    }

    func start(contextProvider: @escaping () -> (selectedSessionID: String?, startedSessionCount: Int)) {
        self.contextProvider = contextProvider
        guard observers.isEmpty else { refreshContext(); return }
        let notifications: [Notification.Name] = [
            NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
            NSApplication.didHideNotification, NSApplication.didUnhideNotification,
            NSApplication.didChangeOcclusionStateNotification,
            Notification.Name.NSProcessInfoPowerStateDidChange
        ]
        observers = notifications.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshContext() }
            }
        }
        // Battery/AC transitions can occur without a low-power-mode change.
        powerSource = IOPSNotificationCreateRunLoopSource({ pointer in
            guard let pointer else { return }
            let diagnostics = Unmanaged<BanyanResourceDiagnostics>.fromOpaque(pointer).takeUnretainedValue()
            MainActor.assumeIsolated { diagnostics.refreshContext() }
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue()
        if let powerSource { CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .commonModes) }
        monitor.start(context: currentContext())
    }

    func refreshContext() { monitor.update(context: currentContext()) }

    func updateSelectedSessionID(_ id: String?) {
        var context = currentContext()
        // @Published emits before the selection property's stored value changes.
        context.selectedSessionID = id
        monitor.update(context: context)
    }

    private func currentContext() -> ResourceCaptureContext {
        let activity: String
        if NSApp.isActive { activity = "active" }
        else if NSApp.isHidden || !NSApp.occlusionState.contains(.visible) { activity = "hidden" }
        else { activity = "background_visible" }
        var isOnBattery = false
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() {
            isOnBattery = (source as String) == kIOPSBatteryPowerValue
        }
        let sessions = contextProvider?()
        return ResourceCaptureContext(
            activity: activity, selectedSessionID: sessions?.selectedSessionID,
            startedSessionCount: sessions?.startedSessionCount ?? 0,
            isOnBattery: isOnBattery, isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        if let powerSource { CFRunLoopSourceInvalidate(powerSource) }
    }
}
