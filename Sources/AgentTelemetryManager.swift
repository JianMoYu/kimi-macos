import Foundation
import Combine
import AppKit

// MARK: - 数据模型

public struct SubAgentItem: Identifiable, Equatable {
    public let id: String
    public let name: String
    public var status: String // "working", "completed", "idle", "failed"
    public var roleDescription: String?
    public var parentId: String?
    public var lastActive: Date

    public init(id: String, name: String, status: String, roleDescription: String? = nil, parentId: String? = nil, lastActive: Date = Date()) {
        self.id = id
        self.name = name
        self.status = status
        self.roleDescription = roleDescription
        self.parentId = parentId
        self.lastActive = lastActive
    }
}

public struct BackgroundTaskItem: Identifiable, Equatable {
    public let id: String
    public let type: String // "bash", "todo", "tool"
    public let description: String
    public var status: String // "running", "completed", "failed"
    public var durationText: String?
    public let startedAt: Date

    public init(id: String, type: String, description: String, status: String, durationText: String? = nil, startedAt: Date = Date()) {
        self.id = id
        self.type = type
        self.description = description
        self.status = status
        self.durationText = durationText
        self.startedAt = startedAt
    }
}

public enum StatScope: String, CaseIterable, Identifiable {
    case session = "按会话"
    case daily = "按天"
    case allTime = "全部"
    public var id: String { rawValue }
}

public struct TokenStatGroup: Equatable {
    public var inputOther: Int = 0
    public var inputCacheRead: Int = 0
    public var inputCacheCreation: Int = 0
    public var output: Int = 0

    public var totalTokens: Int {
        inputOther + inputCacheRead + output
    }

    public var cacheHitRate: Double {
        let totalInput = inputCacheRead + inputOther
        guard totalInput > 0 else { return 0.0 }
        return (Double(inputCacheRead) / Double(totalInput)) * 100.0
    }

    public init(inputOther: Int = 0, inputCacheRead: Int = 0, inputCacheCreation: Int = 0, output: Int = 0) {
        self.inputOther = inputOther
        self.inputCacheRead = inputCacheRead
        self.inputCacheCreation = inputCacheCreation
        self.output = output
    }

    public mutating func add(inputOther: Int, inputCacheRead: Int, inputCacheCreation: Int, output: Int) {
        self.inputOther += inputOther
        self.inputCacheRead += inputCacheRead
        self.inputCacheCreation += inputCacheCreation
        self.output += output
    }
}

// MARK: - Agent 遥测与监控核心管理器

public final class AgentTelemetryManager: ObservableObject {
    public static let shared = AgentTelemetryManager()

    // 运行状态与活动标识
    @Published public var isBusy: Bool = false
    @Published public var activeTurnId: String? = nil
    @Published public var currentTurnPrompt: String? = nil
    @Published public var pendingInteraction: String? = nil

    // SubAgent 与后台任务
    @Published public var subAgents: [SubAgentItem] = []
    @Published public var backgroundTasks: [BackgroundTaskItem] = []

    // 性能与 Token 指标
    @Published public var tokensPerSecond: Double = 0.0
    @Published public var ttftMs: Int? = nil // Time to first token
    @Published public var streamDurationMs: Int? = nil

    // 缓存与上下文指标（单次 Turn / 实时）
    @Published public var contextTokens: Int = 0
    @Published public var contextLimit: Int = 262144
    @Published public var inputCacheRead: Int = 0
    @Published public var inputCacheCreation: Int = 0
    @Published public var inputOther: Int = 0
    @Published public var outputTokens: Int = 0
    @Published public var cacheHitRate: Double = 0.0

    // 常驻 Token 统计维度（按会话 / 按天 / 全部）
    @Published public var sessionStats: TokenStatGroup = TokenStatGroup()
    @Published public var todayStats: TokenStatGroup = TokenStatGroup()
    @Published public var allTimeStats: TokenStatGroup = TokenStatGroup()
    @Published public var sessionStatsMap: [String: TokenStatGroup] = [:]
    @Published public var selectedStatScope: StatScope = .session

    // 当前绑定会话
    @Published public var currentSessionId: String? = nil {
        didSet {
            if oldValue != currentSessionId {
                recalculateCumulativeStats()
            }
        }
    }
    @Published public var currentSessionTitle: String? = nil

    private var pollTimer: Timer? = nil
    private var speedDecayTimer: Timer? = nil
    private var lastInteractionNotified: String? = nil

    public init() {
        startBackgroundSync()
        syncFromLatestSession()
        recalculateCumulativeStats()
    }

    deinit {
        pollTimer?.invalidate()
        speedDecayTimer?.invalidate()
    }

    // MARK: - 实时生成速度衰减控制
    /// 当流式输出完成后，让速度展示保持几秒后优雅归零或平滑淡出
    private func bumpTokenSpeed(_ tps: Double) {
        DispatchQueue.main.async {
            self.tokensPerSecond = tps
            self.speedDecayTimer?.invalidate()
            self.speedDecayTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.tokensPerSecond = 0.0
                }
            }
        }
    }

    // MARK: - WebSocket 实时帧解析（经 WKWebView 注入桥转发）

    public func handleIncomingTelemetryJSON(_ rawJson: String) {
        guard let data = rawJson.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.processTelemetryPayload(obj)
        }
    }

    private func processTelemetryPayload(_ obj: [String: Any]) {
        let eventType = obj["type"] as? String ?? ""

        // 1. 解析 Session ID 与基础事件
        if let sid = obj["session_id"] as? String, !sid.isEmpty {
            self.currentSessionId = sid
        } else if let payload = obj["payload"] as? [String: Any] {
            if let sid = payload["session_id"] as? String, !sid.isEmpty {
                self.currentSessionId = sid
            } else if let sids = payload["session_ids"] as? [String], let firstSid = sids.first, !firstSid.isEmpty {
                self.currentSessionId = firstSid
            }
        }

        // 2. 检查是否有 pending interaction (权限授权 / 用户询问)
        if let pi = obj["pending_interaction"] as? String {
            updatePendingInteraction(pi)
        }

        // 3. 检查 busy 状态
        if let busy = obj["busy"] as? Bool {
            self.isBusy = busy
        }

        // 4. 解析 Usage 与 Token 统计
        var usageDict: [String: Any]? = nil
        if let u = obj["usage"] as? [String: Any] {
            usageDict = u
        } else if let payload = obj["payload"] as? [String: Any], let u = payload["usage"] as? [String: Any] {
            usageDict = u
        } else if let event = obj["event"] as? [String: Any], let u = event["usage"] as? [String: Any] {
            usageDict = u
        }

        if let usage = usageDict {
            applyUsageMetrics(usage)
        }

        // 5. 解析生成耗时与速度 (llmStreamDurationMs / llmFirstTokenLatencyMs)
        var streamMs: Int? = obj["llmStreamDurationMs"] as? Int
        var ttft: Int? = obj["llmFirstTokenLatencyMs"] as? Int

        if streamMs == nil || ttft == nil {
            if let payload = obj["payload"] as? [String: Any] {
                if streamMs == nil { streamMs = payload["llmStreamDurationMs"] as? Int }
                if ttft == nil { ttft = payload["llmFirstTokenLatencyMs"] as? Int }
            }
        }

        if let ttft = ttft {
            self.ttftMs = ttft
        }
        if let streamMs = streamMs {
            self.streamDurationMs = streamMs
            if let out = usageDict?["output"] as? Int, out > 0, streamMs > 0 {
                let tps = (Double(out) / Double(streamMs)) * 1000.0
                bumpTokenSpeed(tps)
            }
        }

        // 6. 解析 Context 长度 (token_counting.measured)
        if eventType == "token_counting.measured" || eventType.contains("token_counting") {
            if let tokens = obj["tokens"] as? Int {
                self.contextTokens = tokens
            } else if let payload = obj["payload"] as? [String: Any], let tokens = payload["tokens"] as? Int {
                self.contextTokens = tokens
            }
        }

        // 7. 解析 step.begin / step.end
        if eventType == "step.begin" {
            self.isBusy = true
        } else if eventType == "turn.ended" || eventType == "prompt.completed" {
            self.isBusy = false
        }

        // 8. 解析 SubAgent 与后台任务事件
        handleAgentOrTaskEvent(eventType: eventType, obj: obj)
    }

    private func applyUsageMetrics(_ usage: [String: Any]) {
        let other = usage["inputOther"] as? Int ?? usage["input_tokens"] as? Int ?? 0
        let out = usage["output"] as? Int ?? usage["output_tokens"] as? Int ?? 0
        let cacheRead = usage["inputCacheRead"] as? Int ?? usage["cache_read_input_tokens"] as? Int ?? 0
        let cacheCreate = usage["inputCacheCreation"] as? Int ?? usage["cache_creation_input_tokens"] as? Int ?? 0

        self.inputOther = other
        self.outputTokens = out
        self.inputCacheRead = cacheRead
        self.inputCacheCreation = cacheCreate

        let totalInput = cacheRead + other
        if totalInput > 0 {
            self.cacheHitRate = (Double(cacheRead) / Double(totalInput)) * 100.0
        } else {
            self.cacheHitRate = 0.0
        }

        // 实时累加至统计模型
        self.sessionStats.add(inputOther: other, inputCacheRead: cacheRead, inputCacheCreation: cacheCreate, output: out)
        self.todayStats.add(inputOther: other, inputCacheRead: cacheRead, inputCacheCreation: cacheCreate, output: out)
        self.allTimeStats.add(inputOther: other, inputCacheRead: cacheRead, inputCacheCreation: cacheCreate, output: out)
        if let sid = self.currentSessionId {
            var current = self.sessionStatsMap[sid] ?? TokenStatGroup()
            current.add(inputOther: other, inputCacheRead: cacheRead, inputCacheCreation: cacheCreate, output: out)
            self.sessionStatsMap[sid] = current
        }
    }

    private func updatePendingInteraction(_ pi: String) {
        if pi == "none" || pi.isEmpty {
            self.pendingInteraction = nil
        } else {
            self.pendingInteraction = pi
            if pi == "permission" && lastInteractionNotified != pi {
                lastInteractionNotified = pi
                AppNotifications.post(
                    title: "Kimi Code 需要你的操作授权",
                    body: "Agent 即将执行敏感操作，请返回窗口进行确认"
                )
            }
        }
    }

    private func handleAgentOrTaskEvent(eventType: String, obj: [String: Any]) {
        if let agentId = obj["agentId"] as? String, agentId != "main" {
            upsertSubAgent(id: agentId, status: isBusy ? "working" : "idle")
        }

        if eventType.contains("terminal") || eventType.contains("task") || eventType.contains("dock") {
            if let desc = obj["description"] as? String ?? (obj["payload"] as? [String: Any])?["description"] as? String {
                let id = obj["id"] as? String ?? UUID().uuidString
                let task = BackgroundTaskItem(id: id, type: "bash", description: desc, status: "running")
                if !backgroundTasks.contains(where: { $0.id == task.id }) {
                    backgroundTasks.insert(task, at: 0)
                    if backgroundTasks.count > 10 { backgroundTasks.removeLast() }
                }
            }
        }
    }

    private func upsertSubAgent(id: String, status: String, name: String? = nil, parentId: String? = "main") {
        let displayName = name ?? (id.hasPrefix("agent-") ? "子 Agent · \(id.replacingOccurrences(of: "agent-", with: ""))" : id)
        if let idx = subAgents.firstIndex(where: { $0.id == id }) {
            subAgents[idx].status = status
            subAgents[idx].lastActive = Date()
        } else {
            let item = SubAgentItem(id: id, name: displayName, status: status, parentId: parentId)
            subAgents.append(item)
        }
    }

    // MARK: - 本地状态同步（从 ~/.kimi-code/ 与 HTTP API 补齐）

    private func startBackgroundSync() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            self?.syncFromLatestSession()
        }
    }

    public func syncFromLatestSession() {
        let port = KimiServiceManager.shared.port
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/v1/sessions") else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 2.0
        if let token = KimiServiceManager.shared.fetchServerToken(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self = self,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }

            var list: [[String: Any]] = []
            if let items = (json["data"] as? [String: Any])?["items"] as? [[String: Any]] {
                list = items
            } else if let directList = json["data"] as? [[String: Any]] {
                list = directList
            }

            guard let latest = list.first else { return }

            DispatchQueue.main.async {
                self.applySessionSummary(latest)
            }
        }.resume()
    }

    private func applySessionSummary(_ session: [String: Any]) {
        guard let sid = session["id"] as? String else { return }
        self.currentSessionId = sid
        self.currentSessionTitle = session["title"] as? String
        self.isBusy = session["busy"] as? Bool ?? false

        if let pi = session["pending_interaction"] as? String {
            updatePendingInteraction(pi)
        }

        if let usage = session["usage"] as? [String: Any] {
            if let inTokens = usage["input_tokens"] as? Int, inTokens > 0 {
                applyUsageMetrics(usage)
            }
            if let ctx = usage["context_tokens"] as? Int, ctx > 0 {
                self.contextTokens = ctx
            }
            if let limit = usage["context_limit"] as? Int, limit > 0 {
                self.contextLimit = limit
            }
        }

        syncSessionDiskState(sessionId: sid, workspaceId: session["workspace_id"] as? String)
    }

    private func syncSessionDiskState(sessionId: String, workspaceId: String?) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            var sessionPath: String? = nil

            if let wid = workspaceId {
                let direct = "\(home)/.kimi-code/sessions/\(wid)/\(sessionId)"
                if FileManager.default.fileExists(atPath: direct) {
                    sessionPath = direct
                }
            }

            if sessionPath == nil {
                let baseDir = "\(home)/.kimi-code/sessions"
                if let subdirs = try? FileManager.default.contentsOfDirectory(atPath: baseDir) {
                    for sub in subdirs {
                        let candidate = "\(baseDir)/\(sub)/\(sessionId)"
                        if FileManager.default.fileExists(atPath: candidate) {
                            sessionPath = candidate
                            break
                        }
                    }
                }
            }

            guard let validSessionPath = sessionPath else { return }
            let stateFile = "\(validSessionPath)/state.json"
            guard let stateData = try? Data(contentsOf: URL(fileURLWithPath: stateFile)),
                  let stateJson = try? JSONSerialization.jsonObject(with: stateData) as? [String: Any] else {
                return
            }

            var discoveredSubAgents: [SubAgentItem] = []
            if let agentsDict = stateJson["agents"] as? [String: [String: Any]] {
                for (agentId, agentInfo) in agentsDict {
                    if agentId == "main" { continue }
                    let parentId = agentInfo["parentAgentId"] as? String ?? "main"
                    let name = "子 Agent · \(agentId.replacingOccurrences(of: "agent-", with: ""))"
                    discoveredSubAgents.append(SubAgentItem(
                        id: agentId,
                        name: name,
                        status: self.isBusy ? "working" : "idle",
                        parentId: parentId
                    ))
                }
            }

            let wireFile = "\(validSessionPath)/agents/main/wire.jsonl"
            self.readTailWireMetrics(filePath: wireFile)

            DispatchQueue.main.async {
                if !discoveredSubAgents.isEmpty {
                    var merged = self.subAgents
                    for newAgent in discoveredSubAgents {
                        if let idx = merged.firstIndex(where: { $0.id == newAgent.id }) {
                            merged[idx].parentId = newAgent.parentId
                        } else {
                            merged.append(newAgent)
                        }
                    }
                    self.subAgents = merged
                }
            }
        }
    }

    private func readTailWireMetrics(filePath: String) {
        guard FileManager.default.fileExists(atPath: filePath),
              let fileHandle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: filePath)) else {
            return
        }
        defer { try? fileHandle.close() }

        let fileSize = fileHandle.seekToEndOfFile()
        let readLength = min(fileSize, 16384)
        fileHandle.seek(toFileOffset: fileSize - readLength)
        let tailData = fileHandle.readDataToEndOfFile()
        guard let text = String(data: tailData, encoding: .utf8) else { return }

        let lines = text.components(separatedBy: "\n").reversed()
        var foundUsage = false
        var foundCount = false

        for line in lines {
            if line.isEmpty { continue }
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            let type = obj["type"] as? String ?? ""
            if !foundUsage && (type == "usage.record" || obj["usage"] != nil) {
                if let usage = obj["usage"] as? [String: Any] {
                    DispatchQueue.main.async {
                        self.applyUsageMetrics(usage)
                    }
                    foundUsage = true
                }
            }
            if !foundCount && (type == "token_counting.measured") {
                if let tokens = obj["tokens"] as? Int {
                    DispatchQueue.main.async {
                        self.contextTokens = tokens
                    }
                    foundCount = true
                }
            }
            if foundUsage && foundCount { break }
        }
    }

    // MARK: - 全量 Token 统计计算（按会话 / 按天 / 全部）

    public func recalculateCumulativeStats() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let sessionsDir = "\(home)/.kimi-code/sessions"
            guard FileManager.default.fileExists(atPath: sessionsDir) else { return }

            var sessionMap: [String: TokenStatGroup] = [:]
            var sessionLatestTimes: [String: Double] = [:]
            var todayGroup = TokenStatGroup()
            var allTimeGroup = TokenStatGroup()
            let calendar = Calendar.current

            let fileManager = FileManager.default
            guard let enumerator = fileManager.enumerator(atPath: sessionsDir) else { return }

            while let relPath = enumerator.nextObject() as? String {
                if relPath.hasSuffix("wire.jsonl") {
                    let fullPath = "\(sessionsDir)/\(relPath)"

                    // 从相对路径中提取 sessionId (包含 session_ 的目录名)
                    var sid: String? = nil
                    for part in relPath.split(separator: "/") {
                        if part.hasPrefix("session_") {
                            sid = String(part)
                            break
                        }
                    }
                    guard let validSid = sid else { continue }

                    guard let fileData = try? Data(contentsOf: URL(fileURLWithPath: fullPath)),
                          let text = String(data: fileData, encoding: .utf8) else {
                        continue
                    }

                    for line in text.components(separatedBy: "\n") {
                        if !line.contains("usage.record") { continue }
                        guard let lineData = line.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                              obj["type"] as? String == "usage.record" else {
                            continue
                        }

                        // 过滤单轮次 turn，防止重复统计已聚合的 session 记录
                        if let scope = obj["usageScope"] as? String, scope != "turn" {
                            continue
                        }

                        guard let usage = obj["usage"] as? [String: Any] else { continue }

                        let io = usage["inputOther"] as? Int ?? usage["input_tokens"] as? Int ?? 0
                        let icr = usage["inputCacheRead"] as? Int ?? usage["cache_read_input_tokens"] as? Int ?? 0
                        let icc = usage["inputCacheCreation"] as? Int ?? usage["cache_creation_input_tokens"] as? Int ?? 0
                        let out = usage["output"] as? Int ?? usage["output_tokens"] as? Int ?? 0

                        var currentStat = sessionMap[validSid] ?? TokenStatGroup()
                        currentStat.add(inputOther: io, inputCacheRead: icr, inputCacheCreation: icc, output: out)
                        sessionMap[validSid] = currentStat

                        allTimeGroup.add(inputOther: io, inputCacheRead: icr, inputCacheCreation: icc, output: out)

                        if let timeNum = obj["time"] as? NSNumber {
                            let timeMs = timeNum.doubleValue
                            if timeMs > (sessionLatestTimes[validSid] ?? 0) {
                                sessionLatestTimes[validSid] = timeMs
                            }
                            let turnDate = Date(timeIntervalSince1970: timeMs / 1000.0)
                            if calendar.isDateInToday(turnDate) {
                                todayGroup.add(inputOther: io, inputCacheRead: icr, inputCacheCreation: icc, output: out)
                            }
                        }
                    }
                }
            }

            // 确定当前展示的会话
            var activeSid = self.currentSessionId
            if activeSid == nil || (sessionMap[activeSid!]?.totalTokens ?? 0) == 0 {
                // 若尚未指定或当前会话为空，选用最近有交互记录的会话
                if let latestSid = sessionLatestTimes.max(by: { $0.value < $1.value })?.key {
                    if activeSid == nil {
                        activeSid = latestSid
                    }
                }
            }

            let finalActiveSid = activeSid
            let finalSessionStat = (finalActiveSid != nil ? sessionMap[finalActiveSid!] : nil) ?? TokenStatGroup()

            DispatchQueue.main.async {
                if self.currentSessionId == nil && finalActiveSid != nil {
                    self.currentSessionId = finalActiveSid
                }
                self.sessionStatsMap = sessionMap
                self.sessionStats = finalSessionStat
                self.todayStats = todayGroup
                self.allTimeStats = allTimeGroup
            }
        }
    }
}
