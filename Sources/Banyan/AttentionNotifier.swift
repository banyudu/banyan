import Foundation
import UserNotifications

@MainActor
final class AttentionNotifier {
    static let shared = AttentionNotifier()

    private var notifiedKeys = Set<String>()
    private var canUseUserNotifications: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    private init() {}

    func requestAuthorization() {
        guard canUseUserNotifications else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notifyIfNeeded(session: BanyanSession, status: SessionStatus) {
        guard [.needInput, .failed, .review].contains(status) else { return }
        guard canUseUserNotifications else { return }
        let key = "\(session.id):\(status.rawValue):\(session.updatedAt.timeIntervalSince1970.rounded())"
        guard !notifiedKeys.contains(key) else { return }
        notifiedKeys.insert(key)

        let content = UNMutableNotificationContent()
        content.title = "\(session.title): \(status.label)"
        content.body = session.cwd
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "banyan-\(key)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func reset(sessionID: String, status: SessionStatus) {
        notifiedKeys = notifiedKeys.filter { !$0.hasPrefix("\(sessionID):\(status.rawValue):") }
    }
}
