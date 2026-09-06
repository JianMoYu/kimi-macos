import Foundation
import AppKit
import UserNotifications

public enum ServiceState: Equatable {
    case checking
    case starting(String)
    case ready
    case error(String)
}

public struct PlanWindow: Codable {
    public let duration: Int?
    public let unit: String?
}

public struct PlanUsageLimit: Codable {
    public let used: Int
    public let limit: Int
    public let reset_at: String?
    public let window: PlanWindow?

    public var percentage: Int {
        guard limit > 0 else { return 0 }
        return Int((Double(used) / Double(limit)) * 100.0)
    }

    public var resetRemainingText: String? {
        guard let reset_at = reset_at else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = formatter.date(from: reset_at)
        if date == nil {
            formatter.formatOptions = [.withInternetDateTime]
            date = formatter.date(from: reset_at)
        }
        guard let targetDate = date else { return nil }
        let diff = targetDate.timeIntervalSince(Date())
        if diff <= 0 { return "已重置" }

        let days = Int(diff) / 86400
        let hours = (Int(diff) % 86400) / 3600
        let minutes = (Int(diff) % 3600) / 60

        if days > 0 {
            return "\(days)天\(hours)小时后重置"
        } else if hours > 0 {
            return "\(hours)小时\(minutes)分后重置"
        } else {
            return "\(max(1, minutes))分钟后重置"
        }
    }
}

public struct PlanUsageData: Codable {
    public let summary: PlanUsageLimit?
    public let limits: [PlanUsageLimit]?
}

public struct PlanUsageResponse: Codable {
    public let code: Int
    public let data: PlanUsageData?
}

public class KimiServiceManager: ObservableObject {
    @Published public var state: ServiceState = .checking
    @Published public var workDir: String
    @Published public var port: Int = 58627
    @Published public var sessionName: String = "kimi-web"
    @Published public var webReloadID: UUID = UUID()
    @Published public var serverVersion: String? = nil
    /// error 状态下是否正在自动重试（供 UI 展示）
    @Published public var autoRetryActive: Bool = false

    // 套餐用量状态
    @Published public var weeklyUsage: PlanUsageLimit? = nil
    @Published public var shortTermUsage: PlanUsageLimit? = nil
    /// 用量历史采样（百分比），用于弹层迷你走势图
    @Published public var weeklyHistory: [Int] = []
    @Published public var shortHistory: [Int] = []

    // 最近工作目录（最多 5 个）
    @Published public var recentDirs: [String] = []

    /// Web UI 资源自愈失败（错误页据此展示「一键修复」按钮）
    @Published public var webUIRepairFailed: Bool = false

    private let workDirKey = "KimiWebWorkDir"
    private let portKey = "KimiWebPort"
    private let recentDirsKey = "KimiRecentDirs"
    private var isPolling = false
    private var usageTimer: Timer? = nil
    private var autoRetryTimer: Timer? = nil
    /// 本轮检测内是否已尝试过 Web UI 自动修复（避免循环 kill 服务）
    private var webUIRepairAttempted = false

    // 配额预警去重状态（进程内即可，重置检测靠百分比大幅回落）
    private var lastWeeklyPct: Int? = nil
    private var lastShortPct: Int? = nil
    private var weeklyNotifiedLevel = 0
    private var shortNotifiedLevel = 0

    public static let shared = KimiServiceManager()

    public init() {
        if let savedDir = UserDefaults.standard.string(forKey: workDirKey),
           !savedDir.isEmpty,
           FileManager.default.fileExists(atPath: savedDir) {
            self.workDir = savedDir
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let candidatePaths = [
                (home as NSString).appendingPathComponent("workspace"),
                (home as NSString).appendingPathComponent("Developer"),
                (home as NSString).appendingPathComponent("Projects"),
                (home as NSString).appendingPathComponent("Downloads/workspace"),
                home
            ]
            self.workDir = candidatePaths.first(where: { FileManager.default.fileExists(atPath: $0) }) ?? home
        }

        let savedPort = UserDefaults.standard.integer(forKey: portKey)
        if savedPort > 0 {
            self.port = savedPort
        }

        self.recentDirs = UserDefaults.standard.stringArray(forKey: recentDirsKey) ?? []
    }

    // MARK: - 最近工作目录

    private func touchRecentDir(_ path: String) {
        var dirs = recentDirs.filter { $0 != path }
        dirs.insert(path, at: 0)
        recentDirs = Array(dirs.prefix(5))
        UserDefaults.standard.set(recentDirs, forKey: recentDirsKey)
    }

    public func updateWorkDir(_ newPath: String) {
        self.workDir = newPath
        UserDefaults.standard.set(newPath, forKey: workDirKey)
        touchRecentDir(newPath)
    }

    // MARK: - Token 与 URL

    public func fetchServerToken() -> String? {
        let tokenPath = ("~/.kimi-code/server.token" as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: tokenPath),
           let content = try? String(contentsOfFile: tokenPath, encoding: .utf8) {
            let token = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty {
                return token
            }
        }

        let envPrefix = buildEnvPrefix()
        let res = Self.runShell("\(envPrefix) tmux capture-pane -pt '\(sessionName)' 2>/dev/null")
        if res.exitCode == 0 {
            let text = res.output
            if let range = text.range(of: "Token:\\s+([A-Za-z0-9_\\-]+)", options: .regularExpression) {
                let matched = String(text[range])
                let parts = matched.components(separatedBy: .whitespaces)
                if let last = parts.last, !last.isEmpty {
                    return last
                }
            }
            if let range = text.range(of: "#token=([A-Za-z0-9_\\-]+)", options: .regularExpression) {
                let matched = String(text[range])
                if let tokenPart = matched.split(separator: "=").last {
                    return String(tokenPart)
                }
            }
        }

        return nil
    }

    public var serviceURL: URL {
        if let token = fetchServerToken(), !token.isEmpty {
            return URL(string: "http://127.0.0.1:\(port)/#token=\(token)")!
        }
        return URL(string: "http://127.0.0.1:\(port)/")!
    }

    // MARK: - 服务生命周期

    public func checkAndStartService(force: Bool = false) {
        if state == .ready && !force {
            return
        }
        guard !isPolling else { return }
        // 手动触发（无 force）视为新一轮检测，允许再次自动修复；
        // 自动重试（force: true）不重置，避免循环 kill 服务。
        if !force {
            webUIRepairAttempted = false
        }
        self.state = .checking
        stopAutoRetry()

        checkApiHealth { [weak self] apiAlive in
            guard let self = self else { return }
            if apiAlive {
                // 后端就绪，还需确认内嵌 Web UI 资源可服务。
                self.checkWebUIHealth { webAlive in
                    if webAlive {
                        DispatchQueue.main.async {
                            self.stopAutoRetry()
                            self.state = .ready
                            self.webUIRepairFailed = false
                            self.startUsagePolling()
                        }
                    } else {
                        self.handleWebUIAssetsBroken()
                    }
                }
            } else {
                DispatchQueue.global(qos: .userInitiated).async {
                    let tmuxRunning = self.isTmuxSessionRunning()
                    if !tmuxRunning {
                        DispatchQueue.main.async {
                            self.state = .starting("正在通过 tmux 启动后台服务...")
                        }
                        self.launchTmuxSession()
                    } else {
                        DispatchQueue.main.async {
                            self.state = .starting("检测到后台会话存在，等待端口就绪...")
                        }
                    }
                    self.startPollingUntilReady()
                }
            }
        }
    }

    public func restartService(newWorkDir: String? = nil) {
        if let dir = newWorkDir {
            self.workDir = dir
            UserDefaults.standard.set(dir, forKey: workDirKey)
            touchRecentDir(dir)
        }

        self.state = .starting("正在重启 Kimi 服务...")
        stopAutoRetry()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            self.killTmuxSession()
            self.waitForPortRelease()
            self.launchTmuxSession()
            self.startPollingUntilReady()
        }
    }

    // MARK: - Web UI 资源自愈

    /// API 就绪但 SPA 静态资源 404（上游 kimi bundle 解压失败的典型症状）。
    /// 重启 kimi web 会重新解压资源到 ~/Library/Caches/kimi-code/web/，实测可修复。
    private func handleWebUIAssetsBroken() {
        if webUIRepairAttempted {
            let message = """
            后端 API 正常，但 Web UI 资源加载失败（kimi 缓存损坏，疑似上游 bug）。\
            自动重启未能恢复。可点击「一键修复」清理缓存重建资源，\
            或手动执行后点击「重新连接」：

            rm -rf ~/Library/Caches/kimi-code/web
            """
            DispatchQueue.main.async {
                self.state = .error(message)
                self.webUIRepairFailed = true
                self.startAutoRetry()
            }
        } else {
            webUIRepairAttempted = true
            DispatchQueue.main.async {
                self.state = .starting("Web UI 资源异常，正在自动修复（重启服务重建资源）...")
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                self.killTmuxSession()
                self.waitForPortRelease()
                self.launchTmuxSession()
                // 修复模式下 kimi 冷启动，放宽轮询预算
                self.startPollingUntilReady(maxAttempts: 40)
            }
        }
    }

    /// 手动一键修复：kill 服务 → 清理 SPA 缓存 → 重新拉起并等待就绪。
    /// 仅清理 kimi-code 自身的 Web UI 缓存目录。
    public func forceRepairWebUI() {
        guard !isPolling else { return }
        state = .starting("正在清理缓存并重建 Web UI 资源...")
        stopAutoRetry()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            self.killTmuxSession()
            let cachePath = ("~/Library/Caches/kimi-code/web" as NSString).expandingTildeInPath
            try? FileManager.default.removeItem(atPath: cachePath)
            self.waitForPortRelease()
            self.launchTmuxSession()
            self.startPollingUntilReady(maxAttempts: 40)
        }
    }

    /// 等待端口释放，避免旧进程未退净时新进程绑定失败
    private func waitForPortRelease(timeout: TimeInterval = 3.0) {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            let (code, _) = Self.runShell("lsof -ti tcp:\(port) 2>/dev/null | grep -q .")
            if code != 0 { return }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    // MARK: - 环境体检

    /// 检查 kimi CLI 与 tmux 是否可用，缺失时返回可直接展示的指引文案；齐全返回 nil。
    public func diagnoseMissingDependencies() -> String? {
        let envPrefix = buildEnvPrefix()
        let kimiRes = Self.runShell("\(envPrefix) command -v kimi 2>/dev/null")
        let tmuxRes = Self.runShell("\(envPrefix) command -v tmux 2>/dev/null")
        let kimiMissing = kimiRes.exitCode != 0 || kimiRes.output.isEmpty
        let tmuxMissing = tmuxRes.exitCode != 0 || tmuxRes.output.isEmpty

        switch (kimiMissing, tmuxMissing) {
        case (false, false):
            return nil
        case (true, false):
            return "未检测到 kimi CLI。安装与配置请参考：\nhttps://github.com/MoonshotAI/kimi-code"
        case (false, true):
            return "未检测到 tmux。请执行安装：\nbrew install tmux"
        case (true, true):
            return "未检测到 kimi CLI 与 tmux。\n  tmux：brew install tmux\n  kimi CLI：https://github.com/MoonshotAI/kimi-code"
        }
    }

    // MARK: - 错误状态自动重试

    /// error 状态下每 10 秒自动重试，服务中途恢复（如用户在终端手动拉起）可自愈
    private func startAutoRetry() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.autoRetryTimer?.invalidate()
            self.autoRetryActive = true
            self.autoRetryTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
                self?.checkAndStartService(force: true)
            }
        }
    }

    private func stopAutoRetry() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.autoRetryTimer?.invalidate()
            self.autoRetryTimer = nil
            self.autoRetryActive = false
        }
    }

    public func openInTerminal() {
        let script = """
        tell application "Terminal"
            activate
            do script "tmux attach -t \(sessionName)"
        end tell
        """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }

    private func startPollingUntilReady(maxAttempts: Int = 25) {
        isPolling = true
        var attempts = 0

        func poll() {
            guard self.isPolling else { return }
            self.checkApiHealth { [weak self] apiAlive in
                guard let self = self else { return }
                if apiAlive {
                    self.isPolling = false
                    // 后端已就绪，再确认 Web UI 资源（SPA bundle）是否可服务。
                    self.checkWebUIHealth { webAlive in
                        if webAlive {
                            DispatchQueue.main.async {
                                self.stopAutoRetry()
                                self.state = .ready
                                self.webUIRepairFailed = false
                                self.webReloadID = UUID()
                                self.startUsagePolling()
                            }
                        } else {
                            self.handleWebUIAssetsBroken()
                        }
                    }
                } else {
                    attempts += 1
                    if attempts >= maxAttempts {
                        self.isPolling = false
                        DispatchQueue.main.async {
                            let message: String
                            if let missing = self.diagnoseMissingDependencies() {
                                message = "Kimi 服务启动超时。\n\n\(missing)"
                            } else {
                                message = "Kimi 服务启动响应超时（kimi CLI 与 tmux 均已就绪）。请点击「重新连接」重试。"
                            }
                            self.state = .error(message)
                            self.startAutoRetry()
                        }
                    } else {
                        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5) {
                            poll()
                        }
                    }
                }
            }
        }

        poll()
    }

    // MARK: - 用量轮询与配额预警

    public func startUsagePolling() {
        fetchUsage()
        fetchMetaVersion()
        DispatchQueue.main.async { [weak self] in
            self?.usageTimer?.invalidate()
            self?.usageTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
                self?.fetchUsage()
            }
        }
    }

    public func stopUsagePolling() {
        DispatchQueue.main.async { [weak self] in
            self?.usageTimer?.invalidate()
            self?.usageTimer = nil
        }
    }

    public func fetchUsage() {
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/v1/oauth/usage") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2.0
        if let token = fetchServerToken(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let data = data,
                  let res = try? JSONDecoder().decode(PlanUsageResponse.self, from: data),
                  let usageData = res.data else { return }
            let weekly = usageData.summary
            let short = usageData.limits?.first(where: { $0.window?.unit == "hour" })
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.weeklyUsage = weekly
                self.shortTermUsage = short
                self.recordHistory(weeklyPct: weekly?.percentage, shortPct: short?.percentage)
                self.evaluateQuotaNotifications(weeklyPct: weekly?.percentage, shortPct: short?.percentage)
            }
        }.resume()
    }

    private func recordHistory(weeklyPct: Int?, shortPct: Int?) {
        if let p = weeklyPct {
            weeklyHistory.append(p)
            if weeklyHistory.count > 120 { weeklyHistory.removeFirst(weeklyHistory.count - 120) }
        }
        if let p = shortPct {
            shortHistory.append(p)
            if shortHistory.count > 120 { shortHistory.removeFirst(shortHistory.count - 120) }
        }
    }

    /// 阈值跨越（80% / 95%）与重置（百分比大幅回落）时发本地通知
    private func evaluateQuotaNotifications(weeklyPct: Int?, shortPct: Int?) {
        if let p = weeklyPct {
            checkQuotaThreshold(name: "周限额", pct: p, last: &lastWeeklyPct, level: &weeklyNotifiedLevel)
        }
        if let p = shortPct {
            checkQuotaThreshold(name: "5小时限额", pct: p, last: &lastShortPct, level: &shortNotifiedLevel)
        }
    }

    private func checkQuotaThreshold(name: String, pct: Int, last: inout Int?, level: inout Int) {
        // 百分比大幅回落视为窗口重置，重新武装阈值并提示配额恢复
        if let prev = last, prev >= 30, pct <= prev - 25 {
            level = 0
            AppNotifications.post(title: "\(name)已重置", body: "配额已恢复，当前用量 \(pct)%")
        }
        if pct >= 95 && level < 95 {
            level = 95
            AppNotifications.post(title: "\(name)已达 95%", body: "配额即将耗尽（当前 \(pct)%），注意节奏")
        } else if pct >= 80 && level < 80 {
            level = 80
            AppNotifications.post(title: "\(name)已用 80%", body: "当前用量 \(pct)%")
        }
        last = pct
    }

    public func fetchMetaVersion() {
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/v1/meta") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataObj = json["data"] as? [String: Any],
                  let ver = dataObj["server_version"] as? String else { return }
            DispatchQueue.main.async {
                self?.serverVersion = ver
            }
        }.resume()
    }

    /// 后端 API 是否就绪。探测 /api/v1/meta —— 这是后端真实的健康信号。
    /// 不要用 / 作为健康检查：上游 kimi 的 SPA bundle 解压失败时 / 返回 404，
    /// 但 API 独立可用（2026-09 kimi 0.40.1 缓存损坏事故）。
    private func checkApiHealth(completion: @escaping (Bool) -> Void) {
        probeURL(path: "/api/v1/meta", completion: completion)
    }

    /// 内嵌 Web UI（SPA 静态资源）是否可服务。
    private func checkWebUIHealth(completion: @escaping (Bool) -> Void) {
        probeURL(path: "/", completion: completion)
    }

    private func probeURL(path: String, completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else {
            completion(false)
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.0
        request.httpMethod = "GET"

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = 1.0
        sessionConfig.timeoutIntervalForResource = 1.0
        let session = URLSession(configuration: sessionConfig)

        let task = session.dataTask(with: request) { _, response, _ in
            if let httpResponse = response as? HTTPURLResponse, (200...399).contains(httpResponse.statusCode) {
                completion(true)
            } else {
                completion(false)
            }
        }
        task.resume()
    }

    private func isTmuxSessionRunning() -> Bool {
        let envPrefix = buildEnvPrefix()
        let cmd = "\(envPrefix) tmux has-session -t '\(sessionName)' 2>/dev/null"
        let (code, _) = Self.runShell(cmd)
        return code == 0
    }

    private func launchTmuxSession() {
        let envPrefix = buildEnvPrefix()
        let cmd = "\(envPrefix) tmux new-session -d -s '\(sessionName)' -c '\(workDir)' \"kimi web --port \(port) --no-open --dangerous-bypass-auth\""
        _ = Self.runShell(cmd)
    }

    private func killTmuxSession() {
        let envPrefix = buildEnvPrefix()
        let cmd = "\(envPrefix) tmux kill-session -t '\(sessionName)' 2>/dev/null || true"
        _ = Self.runShell(cmd)
    }

    private func buildEnvPrefix() -> String {
        return "export PATH=\"/opt/homebrew/bin:/usr/local/bin:$HOME/.kimi-code/bin:$HOME/.local/bin:$PATH\"; "
    }

    @discardableResult
    public static func runShell(_ command: String) -> (exitCode: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", command]
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return (process.terminationStatus, output.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return (-1, error.localizedDescription)
        }
    }
}
