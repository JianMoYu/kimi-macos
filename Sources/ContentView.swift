import SwiftUI
import AppKit

public struct ContentView: View {
    @ObservedObject var manager = KimiServiceManager.shared

    @State private var pendingNewDir: String? = nil
    @State private var showChangeDirAlert = false
    @State private var showRestartConfirm = false

    public init() {}

    private var currentFolderName: String {
        let url = URL(fileURLWithPath: manager.workDir)
        return url.lastPathComponent.isEmpty ? manager.workDir : url.lastPathComponent
    }

    public var body: some View {
        VStack(spacing: 0) {
            // 顶部工具栏（显示工作目录、用量监控、状态控制）
            headerToolbar
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // 主展示区域
            ZStack {
                switch manager.state {
                case .ready:
                    KimiWebView(url: manager.serviceURL, reloadTrigger: $manager.webReloadID)
                        .edgesIgnoringSafeArea(.all)
                case .checking:
                    loadingView(title: "正在检查服务状态...", subtitle: "正在探测 http://127.0.0.1:\(manager.port)/")
                case .starting(let message):
                    loadingView(title: message, subtitle: "工作目录: \(manager.workDir)")
                case .error(let message):
                    errorView(message: message)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            manager.checkAndStartService()
        }
        .alert("切换工作目录", isPresented: $showChangeDirAlert, presenting: pendingNewDir) { newDir in
            Button("立即重启并生效", role: .destructive) {
                manager.restartService(newWorkDir: newDir)
            }
            Button("仅更新设置（下次启动生效）") {
                manager.updateWorkDir(newDir)
            }
            Button("取消", role: .cancel) {}
        } message: { newDir in
            Text("已选择目录：\n\(newDir)\n\nKimi Code 需要重启后台服务才能应用新目录。是否立即重启？")
        }
        .alert("重启 Kimi 服务", isPresented: $showRestartConfirm) {
            Button("立即重启", role: .destructive) {
                manager.restartService()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("重启后台服务将自动加载最新的 Kimi Code 版本并刷新状态。\n\n当前工作目录：\n\(manager.workDir)")
        }
    }

    // MARK: - 顶部工具栏
    private var headerToolbar: some View {
        HStack(spacing: 12) {
            // 左侧：当前工作目录与切换按钮
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .foregroundColor(.accentColor)
                    .imageScale(.medium)

                VStack(alignment: .leading, spacing: 1) {
                    Text(currentFolderName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(manager.workDir)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .help(manager.workDir)

                Button(action: selectNewDirectory) {
                    Label("更改目录", systemImage: "arrow.triangle.swap")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("选择新的工作目录")

                Button(action: {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: manager.workDir)
                }) {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("在访达中打开当前目录")
            }

            Spacer()

            // 中间：直接显示套餐用量看板
            usageBannerView

            Spacer()

            // 右侧：状态指示与控制操作
            HStack(spacing: 8) {
                statusIndicator

                Button(action: { showRestartConfirm = true }) {
                    Label("重启服务", systemImage: "arrow.clockwise.circle")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("重启后台服务（更新 Kimi Code 后点击生效）")

                Button(action: {
                    manager.webReloadID = UUID()
                    manager.fetchUsage()
                }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut("r", modifiers: [.command])
                .help("刷新页面与用量 (Cmd+R)")
            }
        }
    }

    // MARK: - 套餐用量直接展示组件
    @ViewBuilder
    private var usageBannerView: some View {
        if let weekly = manager.weeklyUsage {
            HStack(spacing: 10) {
                // 每周用量
                HStack(spacing: 5) {
                    Circle()
                        .fill(usageColor(percentage: weekly.percentage))
                        .frame(width: 7, height: 7)

                    Text("周用量: \(weekly.percentage)%")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(usageColor(percentage: weekly.percentage))

                    if let reset = weekly.resetRemainingText {
                        Text("(\(reset))")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                .help("每周限额：已使用 \(weekly.used)/\(weekly.limit) (\(weekly.percentage)%)\n重置时间：\(weekly.resetRemainingText ?? "暂无")")

                // 分隔竖线
                if let short = manager.shortTermUsage {
                    Divider()
                        .frame(height: 12)

                    // 5小时用量
                    HStack(spacing: 5) {
                        Circle()
                            .fill(usageColor(percentage: short.percentage))
                            .frame(width: 7, height: 7)

                        Text("5小时: \(short.percentage)%")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(usageColor(percentage: short.percentage))

                        if let reset = short.resetRemainingText {
                            Text("(\(reset))")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    }
                    .help("5小时限额：已使用 \(short.used)/\(short.limit) (\(short.percentage)%)\n重置时间：\(short.resetRemainingText ?? "暂无")")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.85))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
            )
            .onTapGesture {
                manager.fetchUsage()
            }
        }
    }

    private func usageColor(percentage: Int) -> Color {
        if percentage >= 90 {
            return .red
        } else if percentage >= 70 {
            return .orange
        } else {
            return .green
        }
    }

    // MARK: - 状态指示器
    private var statusIndicator: some View {
        HStack(spacing: 6) {
            switch manager.state {
            case .ready:
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
                if let ver = manager.serverVersion {
                    Text("v\(ver)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                } else {
                    Text("运行中")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            case .starting, .checking:
                ProgressView()
                    .controlSize(.mini)
                Text("启动中...")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
            case .error:
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                Text("连接失败")
                    .font(.system(size: 11))
                    .foregroundColor(.red)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
        .cornerRadius(12)
    }

    // MARK: - 加载过渡界面
    private func loadingView(title: String, subtitle: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 52))
                .foregroundColor(.accentColor)

            Text("Kimi Code")
                .font(.system(size: 22, weight: .bold))

            ProgressView()
                .controlSize(.regular)
                .padding(.top, 4)

            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.primary)

            Text(subtitle)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - 错误异常界面
    private func errorView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundColor(.yellow)

            Text("服务暂未响应")
                .font(.system(size: 20, weight: .bold))

            Text(message)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)

            if manager.autoRetryActive {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("每 10 秒自动重试中，服务恢复后将自动连接")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            HStack(spacing: 12) {
                Button("重新连接") {
                    manager.checkAndStartService()
                }
                .buttonStyle(.borderedProminent)

                Button("更改工作目录") {
                    selectNewDirectory()
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - 弹出系统文件夹选择框
    private func selectNewDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择 Kimi Code 工作目录"
        panel.message = "请选择项目代码所在的文件目录"
        panel.prompt = "选择"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: manager.workDir)

        if panel.runModal() == .OK, let selectedURL = panel.url {
            let path = selectedURL.path
            if path != manager.workDir {
                self.pendingNewDir = path
                self.showChangeDirAlert = true
            }
        }
    }
}
