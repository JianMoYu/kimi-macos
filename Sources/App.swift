import SwiftUI
import AppKit

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
