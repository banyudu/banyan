import AppKit
import BanyanCore
import Foundation
import UserNotifications

@MainActor
final class AttentionNotifier: NSObject, UNUserNotificationCenterDelegate {
    private var notifiedKeys = Set<String>()
    private var pendingOpenPuckID: String?
    var onOpenPuckSession: ((String) -> Void)? {
        didSet {
            if let id = pendingOpenPuckID, let onOpenPuckSession {
                pendingOpenPuckID = nil
                onOpenPuckSession(id)
            }
        }
    }
    private var canUseUserNotifications: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    override init() {
        super.init()
        if canUseUserNotifications { UNUserNotificationCenter.current().delegate = self }
    }

    /// Returns whether the event is an ask still pending on that session,
    /// whether or not this process can post notifications.
    @discardableResult
    func notifyPuckAsk(session: PuckSession, event: PuckSessionEvent) -> Bool {
        notifyPuckAsk(id: session.id, title: session.title, cwd: session.cwd,
                      approvalCallID: session.pendingApproval?.callID,
                      questionCallID: session.pendingQuestion?.callID, event: event)
    }

    /// The same ask on a daemon session without a sidebar row. Clicking it
    /// opens the session, which adds it to the working set.
    @discardableResult
    func notifyPuckAsk(summary: PuckSessionSummary, title: String, event: PuckSessionEvent) -> Bool {
        notifyPuckAsk(id: summary.id, title: title, cwd: summary.cwd,
                      approvalCallID: summary.pendingApproval?.callID,
                      questionCallID: summary.pendingQuestion?.callID, event: event)
    }

    private func notifyPuckAsk(id: String, title: String, cwd: String, approvalCallID: String?,
                               questionCallID: String?, event: PuckSessionEvent) -> Bool {
        guard ["approval_pending", "blocked_on_question"].contains(event.kind),
              event.route == "interactive" else { return false }
        let pendingID = event.kind == "approval_pending" ? approvalCallID : questionCallID
        guard let pendingID, pendingID == event.callID else { return false }
        deliver(title: title, body: cwd, label: "Needs an answer", key: "\(id):ask:\(event.cursor)",
                puckSessionID: id)
        return true
    }

    func requestAuthorization() {
        guard canUseUserNotifications else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notifyIfNeeded(session: BanyanSession, status: SessionStatus) {
        guard [.needInput, .failed, .review].contains(status) else { return }
        let key = "\(session.id):\(status.rawValue):\(session.updatedAt.timeIntervalSince1970.rounded())"
        deliver(title: session.title, body: session.cwd, label: status.label, key: key,
                puckSessionID: session is PuckSession ? session.id : nil)
    }

    private func deliver(title: String, body: String, label: String, key: String, puckSessionID: String?) {
        guard canUseUserNotifications else { return }
        guard !notifiedKeys.contains(key) else { return }
        notifiedKeys.insert(key)

        let content = UNMutableNotificationContent()
        content.title = "\(title): \(label)"
        content.body = body
        content.sound = .default
        if let puckSessionID {
            content.userInfo = ["url": "banyan://puck/\(puckSessionID)"]
        }

        let request = UNNotificationRequest(
            identifier: "banyan-\(key)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        if let source = response.notification.request.content.userInfo["url"] as? String,
           let url = URL(string: source), let id = PuckSessionLink.sessionID(from: url) {
            Task { @MainActor [weak self] in
                if let open = self?.onOpenPuckSession { open(id) }
                else { self?.pendingOpenPuckID = id }
                NSApp?.activate(ignoringOtherApps: true)
            }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let isPuckAsk = notification.request.content.userInfo["url"] as? String != nil
        completionHandler(isPuckAsk ? [.banner, .sound] : [])
    }

    func reset(sessionID: String, status: SessionStatus) {
        notifiedKeys = notifiedKeys.filter { !$0.hasPrefix("\(sessionID):\(status.rawValue):") }
    }
}
