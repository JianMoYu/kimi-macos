import Foundation
import UserNotifications
import AppKit

/// 本地通知统一入口：配额预警、配额重置、Web UI（kimi web 页面调用 Notification API）转发的任务完成提醒。
enum AppNotifications {
    static let delegate = NotificationDelegate()
    private static var authorized = false

    static func requestAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            authorized = granted
        }
    }

    static func post(title: String, body: String) {
        guard authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

/// 点击通知 → 激活 App 并唤起（隐藏的）主窗口
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows where window.canBecomeKey {
                window.makeKeyAndOrderFront(nil)
            }
            KimiServiceManager.shared.startUsagePolling()
        }
        completionHandler()
    }

    /// App 在前台时也显示横幅（默认会被系统吞掉）
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
