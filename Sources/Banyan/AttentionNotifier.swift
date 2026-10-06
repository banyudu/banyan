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

    func notifyPuckAsk(session: PuckSession, event: PuckSessionEvent) {
        guard ["approval_pending", "blocked_on_question"].contains(event.kind),
              event.route == "interactive" else { return }
        let pendingID = event.kind == "approval_pending" ? session.pendingApproval?.callID : session.pendingQuestion?.callID
        guard let pendingID, pendingID == event.callID else { return }
        deliver(session: session, label: "Needs an answer", key: "\(session.id):ask:\(event.cursor)")
    }

    func requestAuthorization() {
        guard canUseUserNotifications else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notifyIfNeeded(session: BanyanSession, status: SessionStatus) {
        guard [.needInput, .failed, .review].contains(status) else { return }
        let key = "\(session.id):\(status.rawValue):\(session.updatedAt.timeIntervalSince1970.rounded())"
        deliver(session: session, label: status.label, key: key)
    }

    private func deliver(session: BanyanSession, label: String, key: String) {
        guard canUseUserNotifications else { return }
        guard !notifiedKeys.contains(key) else { return }
        notifiedKeys.insert(key)

        let content = UNMutableNotificationContent()
        content.title = "\(session.title): \(label)"
        content.body = session.cwd
        content.sound = .default
        if session is PuckSession {
            content.userInfo = ["url": "banyan://puck/\(session.id)"]
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
