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
        // 重置通知冷却：App 启动后 8s 内吞掉所有 kimiNotify，避免「打开 App → 旧
        // session 残留通知补发」的反直觉行为。
        NotificationGate.shared.resetLaunchTime()

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

        // 订阅状态、用量与 Agent 运行态，实时刷新图标
        manager.$weeklyUsage
            .combineLatest(manager.$shortTermUsage, manager.$state, AgentTelemetryManager.shared.$isBusy)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _, _ in self?.refreshButton() }
            .store(in: &cancellables)

        // 生成速率单独订阅，让菜单栏的 tok/s 实时跳动
        AgentTelemetryManager.shared.$tokensPerSecond
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshButton() }
            .store(in: &cancellables)

        refreshButton()
    }

    /// 把 App 图标画进菜单栏。macOS 菜单栏图标的标准满高是 22pt（macOS 11+），
    /// 但 appIcon 的 1024x1024 画布里只有约 86% 是内容（圆角矩形 880x880 + 10% 系统留白）。
    /// 旧实现（side=18, zoom=1.2）实际渲染 18pt → 被画布留白吞掉，圆角矩形只到 ~16pt，
    /// 视觉上比微信、YD 等满高图标小一截。
    /// 改为 side=22（菜单栏满高）+ zoom=1.0（不裁剪，让圆角矩形直接顶到画布边界），
    /// 圆角矩形视觉高度 22*0.86 ≈ 18.9pt，与其它 22pt 满高图标基本等高。
    private static func makeMenuBarIcon() -> NSImage? {
        guard let appIcon = NSApp.applicationIconImage else { return nil }
        let side: CGFloat = 22
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            appIcon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
            return true
        }
        image.isTemplate = false
        return image
    }

    private func refreshButton() {
        guard let button = statusItem?.button else { return }

        // 常态只显示 App 图标；Agent 运行时追加生成速率（对 Agent 开发需一眼可见）；
        // 异常「!」、启动中「…」。用量与 Token 明细走悬停 tooltip 与点开菜单。
        let color: NSColor
        let text: String

        switch manager.state {
        case .ready:
            color = .controlAccentColor
            let tps = AgentTelemetryManager.shared.tokensPerSecond
            if AgentTelemetryManager.shared.isBusy {
                text = tps > 0 ? "\(Int(tps))" : "●"
            } else {
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
        let telemetry = AgentTelemetryManager.shared
        var agentStatus = telemetry.isBusy ? "⚡️ Agent 运行中" : "Agent 就绪"
        if !telemetry.subAgents.isEmpty {
            agentStatus += " (\(telemetry.subAgents.count) 个 SubAgent)"
        }
        let speedLine = telemetry.tokensPerSecond > 0 ? " · \(Int(telemetry.tokensPerSecond)) tok/s" : ""
        button.toolTip = "Kimi Code 服务状态\n\(agentStatus)\(speedLine)\n5 小时限额 \(shortPct.map { "\($0)%" } ?? "—") · 周限额 \(weeklyPct.map { "\($0)%" } ?? "—")\nToken 会话 \(formatTokenCount(telemetry.sessionStats.totalTokens)) · 今日 \(formatTokenCount(telemetry.todayStats.totalTokens))"
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

        let telemetry = AgentTelemetryManager.shared
        if telemetry.isBusy {
            let speedText = telemetry.tokensPerSecond > 0 ? " · ⚡️ \(Int(telemetry.tokensPerSecond)) tok/s" : ""
            menu.addItem(makeInfoItem("Agent 生成中\(speedText)"))
        } else if !inspectorVisible, telemetry.contextTokens > 0 {
            // Context 与缓存命中率已常驻在信息面板，仅在面板隐藏时于此补偿显示
            let cacheText = telemetry.cacheHitRate > 0 ? " · 🎯 \(Int(telemetry.cacheHitRate))% 缓存" : ""
            menu.addItem(makeInfoItem("Context: \(formatTokenCount(telemetry.contextTokens))\(cacheText)"))
        }
        if !telemetry.subAgents.isEmpty {
            let workingCount = telemetry.subAgents.filter { $0.status == "working" }.count
            menu.addItem(makeInfoItem("SubAgent: \(telemetry.subAgents.count) 个 (\(workingCount) 活跃)"))
        }

        menu.addItem(.separator())

        if let weekly = manager.weeklyUsage {
            menu.addItem(makeInfoItem("周限额 \(weekly.percentage)% · \(weekly.resetRemainingText ?? "—")"))
        }
        if let short = manager.shortTermUsage {
            menu.addItem(makeInfoItem("5小时限额 \(short.percentage)% · \(short.resetRemainingText ?? "—")"))
        }
        if telemetry.sessionStats.totalTokens > 0 || telemetry.todayStats.totalTokens > 0 {
            menu.addItem(makeInfoItem("Token 会话 \(formatTokenCount(telemetry.sessionStats.totalTokens)) · 今日 \(formatTokenCount(telemetry.todayStats.totalTokens))"))
        }

        menu.addItem(.separator())
        menu.addItem(makeActionItem("打开 Kimi Code", #selector(openMainWindow)))
        menu.addItem(makeActionItem(inspectorVisible ? "隐藏信息面板" : "显示信息面板", #selector(toggleInspector)))
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

    /// 信息面板显示状态，与 ContentView 的 @AppStorage 共享同一个 UserDefaults key；
    /// 未写入过该 key 时按默认显示处理（bool(forKey:) 对缺失键返回 false，需先判空）。
    private var inspectorVisible: Bool {
        if UserDefaults.standard.object(forKey: "KimiShowInspector") == nil { return true }
        return UserDefaults.standard.bool(forKey: "KimiShowInspector")
    }

    @objc private func toggleInspector() {
        openMainWindow()
        UserDefaults.standard.set(!inspectorVisible, forKey: "KimiShowInspector")
    }
}
