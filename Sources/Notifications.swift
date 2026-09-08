import Foundation
import UserNotifications
import AppKit

/// 通知转发门：用于过滤「App 启动后历史 session 残留通知」的反直觉行为。
/// 现象：用户关闭 App → 后台 kimi web 的旧 session 任务完成 → 浏览器 API 调 Notification
/// → App 重新打开后，WKWebView 加载页面，前端恢复状态时把这条旧通知补发出来
/// → 用户看到「我刚开新会话，上一个会话的任务完成」的通知，与认知冲突。
/// 修法：App 启动 / 重新激活后的前 N 秒内吞掉所有 kimiNotify 转发，给 kimi web
/// 完成页面状态恢复的时间窗。N 秒之后的通知视为当前 session 的有效通知。
final class NotificationGate {
    static let shared = NotificationGate()
    private var lastResetAt: Date = Date()
    /// 8s 冷却：足够 kimi web 完成首屏渲染 + session 状态同步 + 订阅恢复；
    /// 又不至于让用户错过真正新会话完成的通知（用户输入 prompt 后至少要 30s+ 才会完成）。
    private let quietPeriod: TimeInterval = 8.0

    /// 通知 App 已完成启动 / 重新激活，重置冷却窗口
    func resetLaunchTime() {
        lastResetAt = Date()
    }

    /// 是否在冷却期内。是的话通知应被吞掉。
    var isInQuietPeriod: Bool {
        Date().timeIntervalSince(lastResetAt) < quietPeriod
    }
}

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
