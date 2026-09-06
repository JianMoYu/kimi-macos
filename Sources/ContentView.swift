import SwiftUI
import AppKit

public struct ContentView: View {
    @ObservedObject var manager = KimiServiceManager.shared

    @State private var pendingNewDir: String? = nil
    @State private var showChangeDirAlert = false
    @State private var showRestartConfirm = false
    @State private var showUsagePopover = false
    @State private var fixCommandCopied = false

    public init() {}

    private var currentFolderName: String {
        let url = URL(fileURLWithPath: manager.workDir)
        return url.lastPathComponent.isEmpty ? manager.workDir : url.lastPathComponent
    }

    public var body: some View {
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
        .toolbar {
            ToolbarItem(placement: .navigation) {
                workDirMenu
            }
            ToolbarItem(placement: .principal) {
                usagePill
            }
            ToolbarItemGroup(placement: .primaryAction) {
                statusIndicator
                moreMenu
            }
        }
        .popover(isPresented: $showUsagePopover, arrowEdge: .bottom) {
            UsagePopoverView(manager: manager)
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

    // MARK: - 工作目录菜单（含最近目录）

    private var workDirMenu: some View {
        Menu {
            Section {
                Text(manager.workDir)
                    .font(.system(size: 10))
            }
            if manager.recentDirs.filter({ $0 != manager.workDir }).isEmpty == false {
                Section("最近使用") {
                    ForEach(manager.recentDirs.filter { $0 != manager.workDir }, id: \.self) { dir in
                        Button {
                            pendingNewDir = dir
                            showChangeDirAlert = true
                        } label: {
                            Text(URL(fileURLWithPath: dir).lastPathComponent)
                        }
                    }
                }
            }
            Section {
                Button {
                    selectNewDirectory()
                } label: {
                    Label("选择其他目录...", systemImage: "folder.badge.plus")
                }
                Button {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: manager.workDir)
                } label: {
                    Label("在访达中打开", systemImage: "arrow.up.forward.app")
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "folder.fill")
                    .foregroundColor(.accentColor)
                Text(currentFolderName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.secondary)
            }
        }
        .help(manager.workDir)
    }

    // MARK: - 用量胶囊条（迷你进度条版）

    private var usagePill: some View {
        Group {
            if manager.weeklyUsage != nil || manager.shortTermUsage != nil {
                HStack(spacing: 8) {
                    UsageMiniBar(title: "周用量", usage: manager.weeklyUsage)
                    if manager.shortTermUsage != nil {
                        Divider()
                            .frame(height: 12)
                        UsageMiniBar(title: "5小时", usage: manager.shortTermUsage)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color.secondary.opacity(0.18), lineWidth: 0.5))
                .contentShape(Capsule())
                .onTapGesture {
                    manager.fetchUsage()
                    showUsagePopover = true
                }
                .help("点击查看用量详情")
            } else {
                Text("用量加载中...")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - 「⋯」菜单（收纳低频操作）

    private var moreMenu: some View {
        Menu {
            Button {
                showRestartConfirm = true
            } label: {
                Label("重启后台服务...", systemImage: "arrow.clockwise.circle")
            }
            Button {
                manager.openInTerminal()
            } label: {
                Label("在终端打开 tmux", systemImage: "terminal")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .help("更多操作")
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
                }
            case .starting, .checking:
                ProgressView()
                    .controlSize(.mini)
            case .error:
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
            }
        }
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
        .background(Color(nsColor: .windowBackgroundColor))
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
                .textSelection(.enabled)
                .frame(maxWidth: 480)

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

                if manager.webUIRepairFailed {
                    Button("一键修复（清理缓存重建）") {
                        manager.forceRepairWebUI()
                    }
                    .buttonStyle(.bordered)
                }

                Button {
                    let cmd = "rm -rf ~/Library/Caches/kimi-code/web\ntmux kill-session -t kimi-web"
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(cmd, forType: .string)
                    fixCommandCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        fixCommandCopied = false
                    }
                } label: {
                    Label(fixCommandCopied ? "已复制" : "复制修复命令",
                          systemImage: fixCommandCopied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)

                Button("更改工作目录") {
                    selectNewDirectory()
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
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

// MARK: - 迷你进度条（工具栏用量胶囊）

struct UsageMiniBar: View {
    let title: String
    let usage: PlanUsageLimit?

    private var barColor: Color {
        guard let usage = usage else { return .secondary }
        return usageColor(percentage: usage.percentage)
    }

    var body: some View {
        if let usage = usage {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text("\(usage.percentage)%")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(barColor)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.18))
                        Capsule()
                            .fill(barColor)
                            .frame(width: geo.size.width * min(1.0, Double(usage.percentage) / 100.0))
                    }
                }
                .frame(width: 46, height: 3)
            }
            .help("\(title)：已使用 \(usage.used)/\(usage.limit) (\(usage.percentage)%)\n\(usage.resetRemainingText ?? "")")
        }
    }
}

func usageColor(percentage: Int) -> Color {
    if percentage >= 90 {
        return .red
    } else if percentage >= 70 {
        return .orange
    } else {
        return .green
    }
}

// MARK: - 用量详情弹层

struct UsagePopoverView: View {
    @ObservedObject var manager: KimiServiceManager

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let weekly = manager.weeklyUsage {
                UsageDetailRow(
                    title: "周限额",
                    usage: weekly,
                    history: manager.weeklyHistory
                )
            }
            if manager.weeklyUsage != nil && manager.shortTermUsage != nil {
                Divider()
            }
            if let short = manager.shortTermUsage {
                UsageDetailRow(
                    title: "5 小时限额",
                    usage: short,
                    history: manager.shortHistory
                )
            }
            if manager.weeklyUsage == nil && manager.shortTermUsage == nil {
                Text("暂无用量数据")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            Divider()

            HStack(spacing: 10) {
                Button {
                    manager.fetchUsage()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                Button {
                    manager.openInTerminal()
                } label: {
                    Label("在终端打开", systemImage: "terminal")
                }
                Spacer()
                if let ver = manager.serverVersion {
                    Text("v\(ver)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}

struct UsageDetailRow: View {
    let title: String
    let usage: PlanUsageLimit
    let history: [Int]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(usage.percentage)%")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(usageColor(percentage: usage.percentage))
            }

            HStack(spacing: 4) {
                Text("已用 \(usage.used) / \(usage.limit)")
                if let reset = usage.resetRemainingText {
                    Text("·")
                    Text(reset)
                }
            }
            .font(.system(size: 11))
            .foregroundColor(.secondary)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.15))
                    Capsule()
                        .fill(usageColor(percentage: usage.percentage))
                        .frame(width: geo.size.width * min(1.0, Double(usage.percentage) / 100.0))
                }
            }
            .frame(height: 3)

            // 采样足够才画走势，否则只是几条误读为「杂线」的水平线
            if history.count >= 10 {
                Text("近期走势")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .padding(.top, 2)
                UsageSparkline(values: history, color: usageColor(percentage: usage.percentage))
                    .frame(height: 26)
            }
        }
    }
}

// MARK: - 用量走势迷你图

struct UsageSparkline: View {
    let values: [Int]
    let color: Color

    var body: some View {
        GeometryReader { geo in
            if values.count >= 2 {
                let width = geo.size.width
                let height = geo.size.height
                let points: [CGPoint] = values.enumerated().map { index, value in
                    CGPoint(
                        x: width * CGFloat(index) / CGFloat(values.count - 1),
                        y: height * (1.0 - CGFloat(min(100, max(0, value))) / 100.0)
                    )
                }
                ZStack {
                    Path { path in
                        path.move(to: points[0])
                        points.dropFirst().forEach { path.addLine(to: $0) }
                        path.addLine(to: CGPoint(x: width, y: height))
                        path.addLine(to: CGPoint(x: 0, y: height))
                        path.closeSubpath()
                    }
                    .fill(color.opacity(0.12))

                    Path { path in
                        path.move(to: points[0])
                        points.dropFirst().forEach { path.addLine(to: $0) }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            } else {
                Text("走势采集中...")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
    }
}
