import Foundation

/// Tracks notifications from terminal sessions.
/// Notifications come from:
/// - OSC 9 escape sequences (terminal notifications)
/// - Hook handler state changes (Codex feedback)
/// - Shell integration hooks (command completion)
class NotificationStore: ObservableObject {
    static let shared = NotificationStore()

    @Published var notifications: [PairNotification] = []
    @Published var unreadCount: Int = 0

    func addNotification(sessionId: String, title: String, body: String, type: NotificationType = .info) {
        let notification = PairNotification(
            id: UUID().uuidString,
            sessionId: sessionId,
            title: title,
            body: body,
            type: type,
            createdAt: Date(),
            isRead: false
        )
        DispatchQueue.main.async { [weak self] in
            self?.notifications.insert(notification, at: 0)
            self?.unreadCount += 1
            // Keep last 50 notifications
            if let count = self?.notifications.count, count > 50 {
                self?.notifications = Array(self!.notifications.prefix(50))
            }
        }

        // Also show macOS notification for feedback
        if type == .codexFeedback {
            showSystemNotification(title: "Codex: \(title)", body: body)
        }
    }

    func markAllRead() {
        for i in notifications.indices {
            notifications[i].isRead = true
        }
        unreadCount = 0
    }

    func markRead(sessionId: String) {
        for i in notifications.indices {
            if notifications[i].sessionId == sessionId {
                notifications[i].isRead = true
            }
        }
        unreadCount = notifications.filter { !$0.isRead }.count
    }

    private func showSystemNotification(title: String, body: String) {
        let notification = NSUserNotification()
        notification.title = title
        notification.informativeText = String(body.prefix(200))
        notification.soundName = NSUserNotificationDefaultSoundName
        NSUserNotificationCenter.default.deliver(notification)
    }
}

struct PairNotification: Identifiable {
    let id: String
    let sessionId: String
    let title: String
    let body: String
    let type: NotificationType
    let createdAt: Date
    var isRead: Bool
}

enum NotificationType {
    case info
    case codexFeedback
    case codexApprove
    case error
    case shellCommand
}
