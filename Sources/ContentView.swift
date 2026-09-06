import SwiftUI
import AppKit

public struct ContentView: View {
    @ObservedObject var manager = KimiServiceManager.shared
    @ObservedObject var telemetry = AgentTelemetryManager.shared

    @State private var webEstimatedProgress: Double = 0.0
    @State private var showRestartConfirm = false
    @State private var showUsagePopover = false
    @State private var showAgentInspector = false
    @State private var showTokenStatsPopover = false
    @State private var fixCommandCopied = false
    @State private var showErrorDetails = false

    public init() {}

    public var body: some View {
        ZStack(alignment: .top) {
            switch manager.state {
            case .ready:
                KimiWebView(
                    url: manager.serviceURL,
                    reloadTrigger: $manager.webReloadID,
                    estimatedProgress: $webEstimatedProgress
                )
                .edgesIgnoringSafeArea(.all)

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
                HStack(spacing: 8) {
                    AgentHUDCapsule(telemetry: telemetry) {
                        telemetry.syncFromLatestSession()
                        showAgentInspector = true
                    }
                    usagePill
                }
                .padding(.horizontal, 14)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                tokenStatsPill
                moreMenu
            }
        }
        .popover(isPresented: $showUsagePopover, arrowEdge: .bottom) {
            UsagePopoverView(manager: manager)
        }
        .popover(isPresented: $showAgentInspector, arrowEdge: .bottom) {
            AgentInspectorPopover(telemetry: telemetry)
        }
        .popover(isPresented: $showTokenStatsPopover, arrowEdge: .bottom) {
            TokenStatsCardView(telemetry: telemetry)
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

    // MARK: - 用量胶囊条（迷你进度条版）

    private var usagePill: some View {
        Group {
            if manager.weeklyUsage != nil || manager.shortTermUsage != nil {
                Button {
                    manager.fetchUsage()
                    showUsagePopover = true
                } label: {
                    HStack(spacing: 8) {
                        UsageMiniBar(title: "周", usage: manager.weeklyUsage)
                        if manager.shortTermUsage != nil {
                            Divider()
                                .frame(height: 11)
                            UsageMiniBar(title: "5小时", usage: manager.shortTermUsage)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("查看套餐用量")
                .accessibilityLabel("套餐用量")
            } else {
                ProgressView()
                    .controlSize(.mini)
                    .help("正在加载套餐用量")
            }
        }
    }

    // MARK: - 常驻 Token 统计胶囊（按会话 / 今日，常驻显示无需点击）

    private var tokenStatsPill: some View {
        Button {
            telemetry.recalculateCumulativeStats()
            showTokenStatsPopover = true
        } label: {
            HStack(spacing: 8) {
                tokenSummary(title: "会话", count: telemetry.sessionStats.totalTokens, color: Color(red: 0.38, green: 0.30, blue: 0.95))

                Divider()
                    .frame(height: 11)

                tokenSummary(title: "今日", count: telemetry.todayStats.totalTokens, color: .orange)

                statusIndicator

                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("查看 Token 明细")
        .accessibilityLabel("Token 统计")
        .accessibilityValue("会话 \(formatTokenCount(telemetry.sessionStats.totalTokens))，今日 \(formatTokenCount(telemetry.todayStats.totalTokens))")
    }

    private func tokenSummary(title: String, count: Int, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Text(formatTokenCount(count))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
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
                telemetry.syncFromLatestSession()
                showAgentInspector = true
            } label: {
                Label("打开 Agent 监视面板", systemImage: "cpu")
            }
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

// MARK: - Agent 监视看板 Popover

struct AgentInspectorPopover: View {
    @ObservedObject var telemetry: AgentTelemetryManager

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 顶部标题与状态标识
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "cpu.fill")
                        .foregroundColor(.accentColor)
                    Text("Agent 遥测与监视")
                        .font(.system(size: 13, weight: .bold))
                }
                Spacer()
                HStack(spacing: 5) {
                    Circle()
                        .fill(telemetry.isBusy ? Color.cyan : Color.secondary.opacity(0.5))
                        .frame(width: 7, height: 7)
                    Text(telemetry.isBusy ? "生成/执行中" : "就绪")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(telemetry.isBusy ? .cyan : .secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.secondary.opacity(0.1))
                .clipShape(Capsule())
            }

            Divider()

            // 1. Token 性能与缓存指标面板
            VStack(alignment: .leading, spacing: 10) {
                Text("性能与 Prompt 缓存")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)

                HStack(spacing: 12) {
                    metricCard(
                        title: "生成速率",
                        value: telemetry.tokensPerSecond > 0 ? String(format: "%.1f", telemetry.tokensPerSecond) : "待机",
                        unit: telemetry.tokensPerSecond > 0 ? "tok/s" : "",
                        accentColor: .primary
                    )
                    metricCard(
                        title: "首字响应 (TTFT)",
                        value: telemetry.ttftMs != nil ? "\(telemetry.ttftMs!)" : "—",
                        unit: telemetry.ttftMs != nil ? "ms" : "",
                        accentColor: .primary
                    )
                    metricCard(
                        title: "Prompt 缓存命中",
                        value: telemetry.cacheHitRate > 0 ? String(format: "%.1f", telemetry.cacheHitRate) : "—",
                        unit: telemetry.cacheHitRate > 0 ? "%" : "",
                        accentColor: .green
                    )
                }

                // 上下文容量进度条
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("上下文占用 (Context Window)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(formatTokenCount(telemetry.contextTokens)) / \(formatTokenCount(telemetry.contextLimit)) (\(String(format: "%.1f%%", Double(telemetry.contextTokens) / Double(max(1, telemetry.contextLimit)) * 100.0)))")
                            .font(.system(size: 11, weight: .medium))
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
                .padding(.top, 2)

                // 缓存读写明细
                if telemetry.inputCacheRead > 0 || telemetry.inputOther > 0 {
                    HStack(spacing: 10) {
                        Text("命中: \(formatTokenCount(telemetry.inputCacheRead))")
                        Text("·")
                        Text("新增输入: \(formatTokenCount(telemetry.inputOther))")
                        if telemetry.inputCacheCreation > 0 {
                            Text("·")
                            Text("写入: \(formatTokenCount(telemetry.inputCacheCreation))")
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                }
            }

            Divider()

            // 2. SubAgent 并行拓扑
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("活跃 SubAgent")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(telemetry.subAgents.count) 个")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                if telemetry.subAgents.isEmpty {
                    Text("当前会话尚未派生子任务 Agent")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .padding(.vertical, 4)
                } else {
                    VStack(spacing: 6) {
                        ForEach(telemetry.subAgents) { agent in
                            HStack(spacing: 8) {
                                Image(systemName: "cpu")
                                    .font(.system(size: 11))
                                    .foregroundColor(.accentColor)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(agent.name)
                                        .font(.system(size: 12, weight: .medium))
                                    if let parent = agent.parentId {
                                        Text("派生自: \(parent)")
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                                Text(agent.status == "working" ? "运行中" : "就绪")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(agent.status == "working" ? .cyan : .secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(agent.status == "working" ? Color.cyan.opacity(0.12) : Color.secondary.opacity(0.1))
                                    .clipShape(Capsule())
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 6)
                            .background(Color.secondary.opacity(0.04))
                            .cornerRadius(6)
                        }
                    }
                }
            }

            Divider()

            // 3. 后台任务与待办
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("后台任务 (Background Tasks)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(telemetry.backgroundTasks.count) 个")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                if telemetry.backgroundTasks.isEmpty {
                    Text("暂无后台运行的 Bash 或工具任务")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .padding(.vertical, 2)
                } else {
                    ForEach(telemetry.backgroundTasks.prefix(3)) { task in
                        HStack {
                            Image(systemName: "terminal.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            Text(task.description)
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(1)
                            Spacer()
                            Text(task.status)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            Divider()

            // 底部操作与同步
            HStack {
                Button {
                    telemetry.syncFromLatestSession()
                } label: {
                    Label("立即刷新", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)

                Spacer()

                if let sid = telemetry.currentSessionId {
                    Text("Session: \(sid.prefix(12))...")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private func metricCard(title: String, value: String, unit: String, accentColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(accentColor)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(6)
    }
}

// MARK: - 常驻 Token 统计卡片（按会话 / 按天 / 全部 详情面板）

public struct TokenStatsCardView: View {
    @ObservedObject var telemetry: AgentTelemetryManager

    private var currentGroup: TokenStatGroup {
        switch telemetry.selectedStatScope {
        case .session:
            if telemetry.sessionStats.totalTokens > 0 {
                return telemetry.sessionStats
            }
            if let sid = telemetry.currentSessionId, let s = telemetry.sessionStatsMap[sid], s.totalTokens > 0 {
                return s
            }
            return TokenStatGroup(
                inputOther: telemetry.inputOther,
                inputCacheRead: telemetry.inputCacheRead,
                inputCacheCreation: telemetry.inputCacheCreation,
                output: telemetry.outputTokens
            )
        case .daily:
            return telemetry.todayStats
        case .allTime:
            return telemetry.allTimeStats
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 维度切换器（按会话 / 按天 / 全部）
            HStack {
                HStack(spacing: 2) {
                    ForEach(StatScope.allCases) { scope in
                        Text(scope.rawValue)
                            .font(.system(size: 11, weight: telemetry.selectedStatScope == scope ? .semibold : .regular))
                            .foregroundColor(telemetry.selectedStatScope == scope ? .primary : .secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Group {
                                    if telemetry.selectedStatScope == scope {
                                        Capsule()
                                            .fill(Color.primary.opacity(0.12))
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

                Spacer()

                Button {
                    telemetry.recalculateCumulativeStats()
                    telemetry.syncFromLatestSession()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("重新扫描并刷新统计数据")
            }

            // 总 Tokens
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 6) {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                    Text("总 Tokens")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.primary)
                }
                Spacer()
                Text(formatNumberWithCommas(currentGroup.totalTokens))
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
            }

            // 缓存命中率
            HStack(alignment: .firstTextBaseline) {
                Text("缓存命中率")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.primary)
                Spacer()
                Text(String(format: "%.1f%%", currentGroup.cacheHitRate))
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundColor(currentGroup.cacheHitRate >= 80 ? .primary : .secondary)
            }

            // 分割线
            Divider()
                .opacity(0.6)
                .padding(.vertical, 1)

            // 未缓存输入
            HStack {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(red: 0.88, green: 0.90, blue: 0.98))
                        .frame(width: 11, height: 11)
                    Text("未缓存输入")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text(formatNumberWithCommas(currentGroup.inputOther))
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundColor(.primary)
            }

            // 缓存输入
            HStack {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(red: 0.58, green: 0.65, blue: 0.96))
                        .frame(width: 11, height: 11)
                    Text("缓存输入")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text(formatNumberWithCommas(currentGroup.inputCacheRead))
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundColor(.primary)
            }

            // 输出
            HStack {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(red: 0.38, green: 0.30, blue: 0.95))
                        .frame(width: 11, height: 11)
                    Text("输出")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text(formatNumberWithCommas(currentGroup.output))
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundColor(.primary)
            }

            // 底部会话小标识
            if let sid = telemetry.currentSessionId {
                Divider()
                    .opacity(0.3)
                    .padding(.top, 2)
                Text("会话: \(sid.replacingOccurrences(of: "session_", with: ""))")
                    .font(.system(size: 9.5))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(16)
        .frame(width: 260)
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
                .frame(width: 44, height: 3)
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
                    usage: weekly
                )
            }
            if manager.weeklyUsage != nil && manager.shortTermUsage != nil {
                Divider()
            }
            if let short = manager.shortTermUsage {
                UsageDetailRow(
                    title: "5 小时限额",
                    usage: short
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
        }
    }
}
