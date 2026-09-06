import SwiftUI
import AppKit
import Combine
import UserNotifications

@main
struct KimiCodeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // 使用 Window 而不是 WindowGroup，强制声明单窗口实例，严禁生成多窗口
        Window("Kimi Code", id: "main") {
            ContentView()
                .frame(minWidth: 960, minHeight: 620)
                .background(WindowAccessor())
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {} // 禁用系统默认的“新建窗口”快捷键
            CommandMenu("Kimi 控制") {
                Button("重启后台服务") {
                    KimiServiceManager.shared.restartService()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Divider()

                Button("重新载入页面") {
                    KimiServiceManager.shared.webReloadID = UUID()
                    KimiServiceManager.shared.fetchUsage()
                }
                .keyboardShortcut("r", modifiers: [.command])

                Button("在终端打开 tmux") {
                    KimiServiceManager.shared.openInTerminal()
                }
            }
        }
    }
}

// 拦截窗口关闭与尺寸持久化：
// 1. setFrameAutosaveName: 自动记忆用户拖拽调整后的窗口尺寸，下次打开严格保持用户尺寸，绝不重置为默认大小
// 2. windowShouldClose: 点击红叉仅隐藏窗口，保留 WKWebView 内存常驻
// 3. 隐藏/最小化时停止轮询，恢复时启动轮询
struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                context.coordinator.setupWindow(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window, window.delegate !== context.coordinator {
                context.coordinator.setupWindow(window)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, NSWindowDelegate {
        weak var window: NSWindow?

        func setupWindow(_ window: NSWindow) {
            self.window = window
            window.delegate = self
            // 启用系统级窗口尺寸与位置自动记忆
            window.setFrameAutosaveName("KimiMainWindowAutosaveFrame")
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            sender.orderOut(nil)
            // 隐藏窗口后立即停止用量轮询，节省系统资源
            KimiServiceManager.shared.stopUsagePolling()
            return false
        }

        func windowDidMiniaturize(_ notification: Notification) {
            KimiServiceManager.shared.stopUsagePolling()
        }

        func windowDidDeminiaturize(_ notification: Notification) {
            KimiServiceManager.shared.startUsagePolling()
        }

        func windowDidBecomeKey(_ notification: Notification) {
            KimiServiceManager.shared.startUsagePolling()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 外观跟随系统：kimi web UI 自带 light/dark 双主题（其 CSS 依赖
        // prefers-color-scheme，而 WKWebView 继承窗口外观），锁定外观会
        // 连带强制页面主题；加载底色的深浅适配在 WebView 侧处理。

        // 本地通知（配额预警 / 任务完成提醒）
        AppNotifications.requestAuthorization()

        // 菜单栏常驻用量图标
        MenuBarController.shared.install()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // 核心拦截点：当用户点击 Dock 图标重新打开 App 时触发
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // 唤醒所有已隐藏的窗口
        for window in sender.windows where window.canBecomeKey {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            KimiServiceManager.shared.startUsagePolling()
            // 关键：必须返回 false！
            // 返回 true 会让系统以为没有窗口而重新根据默认尺寸创建一个空白新窗口；
            // 返回 false 明确告诉系统：窗口已经由我恢复完毕，严禁创建任何新窗口！
            return false
        }
        return false
    }

    func applicationDidHide(_ notification: Notification) {
        KimiServiceManager.shared.stopUsagePolling()
    }

    func applicationDidUnhide(_ notification: Notification) {
        KimiServiceManager.shared.startUsagePolling()
    }

    func applicationWillTerminate(_ notification: Notification) {
        KimiServiceManager.shared.stopUsagePolling()
    }
}

// MARK: - 菜单栏常驻图标
// App 的核心定位是「窗口藏起来、服务继续跑」，菜单栏是窗口隐藏后的常驻入口：
// 图标显示用量百分比（阈值着色），菜单提供唤起窗口、重载、重启、终端 attach 等快捷操作。

final class MenuBarController: NSObject, NSMenuDelegate {
    static let shared = MenuBarController()

    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()

    private let manager = KimiServiceManager.shared

    func install() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item

        // 菜单栏展示：App 图标 + 用量百分比文字
        item.button?.image = Self.makeMenuBarIcon()

        // 订阅状态与用量变化，实时刷新图标
        manager.$weeklyUsage
            .combineLatest(manager.$shortTermUsage, manager.$state)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _ in self?.refreshButton() }
            .store(in: &cancellables)

        refreshButton()
    }

    /// 把 App 图标缩到菜单栏尺寸（16pt），彩色非模板
    private static func makeMenuBarIcon() -> NSImage? {
        guard let appIcon = NSApp.applicationIconImage else { return nil }
        let target = NSSize(width: 16, height: 16)
        let image = NSImage(size: target, flipped: false) { rect in
            appIcon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
            return true
        }
        image.isTemplate = false
        return image
    }

    private func refreshButton() {
        guard let button = statusItem?.button else { return }

        let color: NSColor
        let text: String

        switch manager.state {
        case .ready:
            if let pct = manager.shortTermUsage?.percentage ?? manager.weeklyUsage?.percentage {
                color = pct >= 90 ? .systemRed : (pct >= 70 ? .systemOrange : .systemGreen)
                text = "\(pct)%"
            } else {
                color = .secondaryLabelColor
                text = ""
            }
        case .error:
            color = .systemRed
            text = "!"
        case .checking, .starting:
            color = .systemOrange
            text = "…"
        }

        // 图标缺失时退回圆点，避免只剩光秃秃的数字
        let prefix = (button.image == nil && !text.isEmpty) ? "● " : ""
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: color,
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        ]
        button.attributedTitle = NSAttributedString(string: prefix + text, attributes: attributes)
        let shortPct = manager.shortTermUsage?.percentage
        let weeklyPct = manager.weeklyUsage?.percentage
        button.toolTip = "Kimi Code 服务状态\n5 小时限额 \(shortPct.map { "\($0)%" } ?? "—") · 周限额 \(weeklyPct.map { "\($0)%" } ?? "—")"
    }

    // 打开菜单时重建条目，保证用量/状态是最新的
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        switch manager.state {
        case .ready:
            let version = manager.serverVersion.map { " · v\($0)" } ?? ""
            menu.addItem(makeInfoItem("服务运行中\(version)"))
        case .error:
            menu.addItem(makeInfoItem("服务未响应"))
        case .checking, .starting:
            menu.addItem(makeInfoItem("服务启动中..."))
        }

        if let weekly = manager.weeklyUsage {
            menu.addItem(makeInfoItem("周限额 \(weekly.percentage)% · \(weekly.resetRemainingText ?? "—")"))
        }
        if let short = manager.shortTermUsage {
            menu.addItem(makeInfoItem("5小时限额 \(short.percentage)% · \(short.resetRemainingText ?? "—")"))
        }

        menu.addItem(.separator())
        menu.addItem(makeActionItem("打开 Kimi Code", #selector(openMainWindow)))
        menu.addItem(makeActionItem("重新载入页面", #selector(reloadPage)))
        menu.addItem(makeActionItem("重启后台服务", #selector(restartService)))
        menu.addItem(makeActionItem("在终端打开 tmux", #selector(attachTerminal)))
        menu.addItem(.separator())
        // 退出走响应链（target 为 nil），正确路由到 NSApplication.terminate
        menu.addItem(NSMenuItem(title: "退出 Kimi Code", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func makeInfoItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        return item
    }

    private func makeActionItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeKey {
            window.makeKeyAndOrderFront(nil)
        }
        manager.startUsagePolling()
    }

    @objc private func reloadPage() {
        manager.webReloadID = UUID()
        manager.fetchUsage()
    }

    @objc private func restartService() {
        openMainWindow()
        manager.restartService()
    }

    @objc private func attachTerminal() {
        manager.openInTerminal()
    }
}
