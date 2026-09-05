import Foundation
import AppKit

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

    // 套餐用量状态
    @Published public var weeklyUsage: PlanUsageLimit? = nil
    @Published public var shortTermUsage: PlanUsageLimit? = nil

    private let workDirKey = "KimiWebWorkDir"
    private let portKey = "KimiWebPort"
    private var isPolling = false
    private var usageTimer: Timer? = nil

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
    }

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

    public func checkAndStartService(force: Bool = false) {
        if state == .ready && !force {
            return
        }
        guard !isPolling else { return }
        self.state = .checking

        checkHttpHealth { [weak self] isAlive in
            guard let self = self else { return }
            if isAlive {
                DispatchQueue.main.async {
                    self.state = .ready
                    self.startUsagePolling()
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
        }

        self.state = .starting("正在重启 Kimi 服务...")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            self.killTmuxSession()
            Thread.sleep(forTimeInterval: 0.5)
            self.launchTmuxSession()
            self.startPollingUntilReady()
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

    public func updateWorkDir(_ newPath: String) {
        self.workDir = newPath
        UserDefaults.standard.set(newPath, forKey: workDirKey)
    }

    private func startPollingUntilReady() {
        isPolling = true
        var attempts = 0
        let maxAttempts = 25

        func poll() {
            guard self.isPolling else { return }
            self.checkHttpHealth { [weak self] isAlive in
                guard let self = self else { return }
                if isAlive {
                    self.isPolling = false
                    DispatchQueue.main.async {
                        self.state = .ready
                        self.webReloadID = UUID()
                        self.startUsagePolling()
                    }
                } else {
                    attempts += 1
                    if attempts >= maxAttempts {
                        self.isPolling = false
                        DispatchQueue.main.async {
                            self.state = .error("Kimi 服务启动响应超时。请检查服务配置。")
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
            DispatchQueue.main.async {
                self?.weeklyUsage = usageData.summary
                self?.shortTermUsage = usageData.limits?.first(where: { $0.window?.unit == "hour" })
            }
        }.resume()
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

    private func checkHttpHealth(completion: @escaping (Bool) -> Void) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
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
