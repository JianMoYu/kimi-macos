import SwiftUI
import AppKit

public struct ContentView: View {
    @ObservedObject var manager = KimiServiceManager.shared
    @ObservedObject var telemetry = AgentTelemetryManager.shared

    /// 信息面板常驻显示状态，持久化到 UserDefaults（对 Agent 开发需长期可见）
    @AppStorage("KimiShowInspector") private var showInspector: Bool = true

    @State private var webEstimatedProgress: Double = 0.0
    @State private var showRestartConfirm = false
    @State private var fixCommandCopied = false
    @State private var showErrorDetails = false

    public init() {}

    public var body: some View {
        ZStack(alignment: .top) {
            switch manager.state {
            case .ready:
                HStack(spacing: 0) {
                    ZStack(alignment: .top) {
                        KimiWebView(
                            url: manager.serviceURL,
                            reloadTrigger: $manager.webReloadID,
                            estimatedProgress: $webEstimatedProgress
                        )

                        // Safari 风格顶部平滑加载进度条
                        if webEstimatedProgress > 0 && webEstimatedProgress < 1.0 {
                            GeometryReader { geo in
                                Rectangle()
                                    .fill(Color.accentColor)
                                    .frame(width: geo.size.width * CGFloat(webEstimatedProgress), height: 2.5)
                                    .animation(.easeInOut(duration: 0.15), value: webEstimatedProgress)
                            }
                            .frame(height: 2.5)
                            .transition(.opacity)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // 常驻信息面板：挤压布局而非浮层，Agent 会话区始终完整可见
                    if showInspector {
                        Divider()
                        AgentInspectorSidebar(telemetry: telemetry, manager: manager)
                            .frame(width: 272)
                            .transition(.move(edge: .trailing))
                    }
                }

            case .checking:
                loadingView(title: "正在检查服务状态...", subtitle: "正在探测 http://127.0.0.1:\(manager.port)/")
            case .starting(let message):
                loadingView(title: message, subtitle: "工作目录: \(manager.workDir)")
            case .error(let message):
                errorView(message: message)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 退出 Liquid Glass：玻璃材质会让 11pt 小字的对比度随网页滚动与主题切换漂移
        .toolbarBackground(.visible, for: .windowToolbar)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 7) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.accentColor.gradient)
                            .frame(width: 22, height: 22)
                        Image(systemName: "sparkles")
                            .foregroundColor(.white)
                            .font(.system(size: 10, weight: .bold))
                    }
                    Text("Kimi Code")
                        .font(.system(size: 13, weight: .semibold))
                }
                .padding(.horizontal, 6)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Kimi Code")
            }
            ToolbarItem(placement: .principal) {
                AgentHUDCapsule(telemetry: telemetry) {
                    telemetry.syncFromLatestSession()
                }
                .padding(.horizontal, 14)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showInspector.toggle()
                    }
                } label: {
                    Image(systemName: "sidebar.right")
                        .foregroundColor(showInspector ? .accentColor : .secondary)
                }
                .help(showInspector ? "隐藏信息面板" : "显示信息面板")
                .accessibilityLabel(showInspector ? "隐藏信息面板" : "显示信息面板")

                moreMenu
            }
        }
        .onAppear {
            manager.checkAndStartService()
        }
        .alert("重启 Kimi 服务", isPresented: $showRestartConfirm) {
            Button("立即重启", role: .destructive) {
                manager.restartService()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("重启后台服务将自动加载最新的 Kimi Code 版本并刷新状态。\n\n当前服务端口：\(manager.port)")
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
            Divider()
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showInspector.toggle()
                }
            } label: {
                Label(showInspector ? "隐藏信息面板" : "显示信息面板", systemImage: "sidebar.right")
            }
            .keyboardShortcut("i", modifiers: [.command])
            Divider()
            if let version = manager.serverVersion {
                Text("Kimi Code v\(version)")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .padding(.horizontal, 8)
        }
        .help("更多操作")
    }

    // MARK: - 状态指示器

    private var statusIndicator: some View {
        Group {
            switch manager.state {
            case .ready:
                Circle()
                    .fill(Color.green)
                    .frame(width: 7, height: 7)
            case .starting, .checking:
                ProgressView()
                    .controlSize(.mini)
            case .error:
                Circle()
                    .fill(Color.red)
                    .frame(width: 7, height: 7)
            }
        }
        .help(statusHelpText)
        .accessibilityLabel(statusHelpText)
    }

    private var statusHelpText: String {
        switch manager.state {
        case .ready:
            return manager.serverVersion.map { "Kimi 服务已连接，版本 \($0)" } ?? "Kimi 服务已连接"
        case .starting, .checking:
            return "正在连接 Kimi 服务"
        case .error:
            return "Kimi 服务未连接"
        }
    }

    // MARK: - 加载过渡界面

    private func loadingView(title: String, subtitle: String) -> some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.10))
                    .frame(width: 86, height: 86)
                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundColor(.accentColor)
            }

            VStack(spacing: 6) {
                Text("Kimi Code")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.primary)
            }

            ProgressView()
                .controlSize(.small)
                .frame(width: 160)

            Text(subtitle)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 40)
        }
        .padding(36)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.08), radius: 24, y: 10)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)。\(subtitle)")
    }

    // MARK: - 错误异常界面

    private func errorView(message: String) -> some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.12))
                    .frame(width: 82, height: 82)
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundColor(.orange)
            }

            VStack(spacing: 7) {
                Text("服务暂未响应")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text("Kimi Code 无法连接到本地服务，你可以先重新连接。")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }

            if manager.autoRetryActive {
                Label("正在自动重试，服务恢复后会立即连接", systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(Capsule())
            }

            HStack(spacing: 10) {
                Button("重新连接") {
                    manager.checkAndStartService()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)

                if manager.webUIRepairFailed {
                    Button("一键修复") {
                        manager.forceRepairWebUI()
                    }
                    .buttonStyle(.bordered)
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showErrorDetails.toggle()
                    }
                } label: {
                    Label(showErrorDetails ? "收起详情" : "查看详情", systemImage: showErrorDetails ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.bordered)
            }

            if showErrorDetails {
                VStack(alignment: .leading, spacing: 10) {
                    Text(message)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack {
                        Text("端口 \(manager.port)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                        Spacer()
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
                        .buttonStyle(.plain)
                    }
                }
                .padding(12)
                .frame(width: 480)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.65))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.secondary.opacity(0.12)))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(36)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.08), radius: 24, y: 10)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Agent 遥测 HUD 胶囊（工具栏）

struct AgentHUDCapsule: View {
    @ObservedObject var telemetry: AgentTelemetryManager
    let onTap: () -> Void

    private var activeSubAgentCount: Int {
        telemetry.subAgents.filter { $0.status == "working" }.count
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 7) {
                if telemetry.isBusy {
                    Circle()
                        .fill(Color.cyan)
                        .frame(width: 7, height: 7)

                    if telemetry.tokensPerSecond > 0 {
                        Text("\(Int(telemetry.tokensPerSecond)) tok/s")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.primary)
                    } else {
                        Text("Agent 运行中")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.primary)
                    }

                    if activeSubAgentCount > 0 {
                        Divider().frame(height: 10)
                        HStack(spacing: 3) {
                            Image(systemName: "person.2.fill")
                                .font(.system(size: 9))
                            Text("\(activeSubAgentCount)")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundColor(.accentColor)
                    }
                } else {
                    Image(systemName: "cpu")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)

                    if telemetry.contextTokens > 0 {
                        Text("Context \(formatTokenCount(telemetry.contextTokens))")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                    } else {
                        Text("Agent 就绪")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("查看 Agent 状态、SubAgent 与 Token 性能")
        .accessibilityLabel(telemetry.isBusy ? "Agent 正在运行" : "Agent 已就绪")
    }
}


// MARK: - 常驻信息面板（右侧挤压式布局，非浮层）
// 设计要点：面板占据独立宽度而非覆盖 Web 区域，Agent 会话内容始终完整可见。
// 显示状态持久化在 KimiShowInspector（@AppStorage），重启后保持用户选择。

public struct AgentInspectorSidebar: View {
    @ObservedObject var telemetry: AgentTelemetryManager
    @ObservedObject var manager: KimiServiceManager

    private var currentGroup: TokenStatGroup {
        switch telemetry.selectedStatScope {
        case .session:
            if telemetry.sessionStats.totalTokens > 0 { return telemetry.sessionStats }
            if let sid = telemetry.currentSessionId,
               let s = telemetry.sessionStatsMap[sid], s.totalTokens > 0 { return s }
            return TokenStatGroup(
                inputOther: telemetry.inputOther,
                inputCacheRead: telemetry.inputCacheRead,
                inputCacheCreation: telemetry.inputCacheCreation,
                output: telemetry.outputTokens
            )
        case .daily:
            return telemetry.todayStats
        case .monthly:
            return telemetry.monthlyStats
        }
    }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 18) {
                statusSection
                usageSection
                tokenSection
                contextSection
                if !telemetry.subAgents.isEmpty { subAgentSection }
                if !telemetry.backgroundTasks.isEmpty { taskSection }
            }
            .padding(14)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear {
            telemetry.recalculateCumulativeStats()
            manager.fetchUsage()
        }
    }

    // MARK: Agent 运行状态

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: "cpu.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.accentColor)
                Text("Agent 状态")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Circle()
                    .fill(telemetry.isBusy ? Color.cyan : Color.secondary.opacity(0.45))
                    .frame(width: 7, height: 7)
                Text(telemetry.isBusy ? "运行中" : "就绪")
                    .font(.system(size: 11))
                    .foregroundColor(telemetry.isBusy ? .cyan : .secondary)
            }

            HStack(spacing: 8) {
                metricCell("生成速率",
                           telemetry.tokensPerSecond > 0 ? String(format: "%.0f", telemetry.tokensPerSecond) : "—",
                           telemetry.tokensPerSecond > 0 ? "tok/s" : "")
                metricCell("首字延迟",
                           telemetry.ttftMs.map { "\($0)" } ?? "—",
                           telemetry.ttftMs != nil ? "ms" : "")
                metricCell("缓存命中",
                           telemetry.cacheHitRate > 0 ? String(format: "%.0f", telemetry.cacheHitRate) : "—",
                           telemetry.cacheHitRate > 0 ? "%" : "")
            }
        }
    }

    // MARK: 套餐用量

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionTitle("套餐用量")
            if manager.weeklyUsage == nil && manager.shortTermUsage == nil {
                Text("暂无用量数据")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            if let weekly = manager.weeklyUsage { usageRow("周限额", weekly) }
            if let short = manager.shortTermUsage { usageRow("5 小时限额", short) }
        }
    }

    private func usageRow(_ title: String, _ usage: PlanUsageLimit) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(usage.percentage)%")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(usageColor(percentage: usage.percentage))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule()
                        .fill(usageColor(percentage: usage.percentage))
                        .frame(width: geo.size.width * min(1.0, Double(usage.percentage) / 100.0))
                }
            }
            .frame(height: 4)
            if let reset = usage.resetRemainingText {
                Text(reset)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: Token 统计

    private var tokenSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                sectionTitle("Token 统计")
                Spacer()
                Button {
                    telemetry.recalculateCumulativeStats(force: true)
                    telemetry.syncFromLatestSession()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("重新扫描本地会话并刷新统计")
            }

            HStack(spacing: 2) {
                ForEach(StatScope.allCases) { scope in
                    Text(scope.rawValue)
                        .font(.system(size: 10, weight: telemetry.selectedStatScope == scope ? .semibold : .regular))
                        .foregroundColor(telemetry.selectedStatScope == scope ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background(
                            Group {
                                if telemetry.selectedStatScope == scope {
                                    Capsule().fill(Color.primary.opacity(0.12))
                                }
                            }
                        )
                        .contentShape(Capsule())
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                telemetry.selectedStatScope = scope
                            }
                        }
                }
            }
            .padding(2)
            .background(Color.secondary.opacity(0.08))
            .clipShape(Capsule())

            tokenRow("总 Tokens", formatNumberWithCommas(currentGroup.totalTokens), emphasized: true)
            tokenRow("缓存输入", formatNumberWithCommas(currentGroup.inputCacheRead))
            tokenRow("未缓存输入", formatNumberWithCommas(currentGroup.inputOther))
            tokenRow("输出", formatNumberWithCommas(currentGroup.output))
            tokenRow("缓存命中率", String(format: "%.1f%%", currentGroup.cacheHitRate))
        }
    }

    // MARK: 上下文占用

    private var contextSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionTitle("上下文占用")
            HStack {
                Text("\(formatTokenCount(telemetry.contextTokens)) / \(formatTokenCount(telemetry.contextLimit))")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                Text(String(format: "%.1f%%", Double(telemetry.contextTokens) / Double(max(1, telemetry.contextLimit)) * 100.0))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: geo.size.width * min(1.0, Double(telemetry.contextTokens) / Double(max(1, telemetry.contextLimit))))
                }
            }
            .frame(height: 4)
        }
    }

    // MARK: SubAgent 与后台任务

    private var subAgentSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                sectionTitle("SubAgent")
                Spacer()
                Text("\(telemetry.subAgents.count) 个")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            ForEach(telemetry.subAgents) { agent in
                HStack(spacing: 7) {
                    Image(systemName: "cpu")
                        .font(.system(size: 10))
                        .foregroundColor(.accentColor)
                    Text(agent.name)
                        .font(.system(size: 11))
                        .lineLimit(1)
                    Spacer()
                    Text(agent.status == "working" ? "运行中" : "就绪")
                        .font(.system(size: 10))
                        .foregroundColor(agent.status == "working" ? .cyan : .secondary)
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 7)
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(6)
            }
        }
    }

    private var taskSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionTitle("后台任务")
            ForEach(Array(telemetry.backgroundTasks.prefix(4))) { task in
                HStack(spacing: 7) {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text(task.description)
                        .font(.system(size: 10.5, design: .monospaced))
                        .lineLimit(1)
                    Spacer()
                    Text(task.status)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: 通用组件

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.secondary)
    }

    private func metricCell(_ title: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(7)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(6)
    }

    private func tokenRow(_ title: String, _ value: String, emphasized: Bool = false) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: emphasized ? 13 : 11,
                              weight: emphasized ? .semibold : .medium,
                              design: .rounded))
                .monospacedDigit()
        }
    }
}

// MARK: - 格式化辅助函数

func formatNumberWithCommas(_ number: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.groupingSeparator = ","
    return formatter.string(from: NSNumber(value: number)) ?? "\(number)"
}

func formatTokenCount(_ count: Int) -> String {
    if count >= 1000000 {
        return String(format: "%.1fM", Double(count) / 1000000.0)
    } else if count >= 1000 {
        return String(format: "%.1fk", Double(count) / 1000.0)
    } else {
        return "\(count)"
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
