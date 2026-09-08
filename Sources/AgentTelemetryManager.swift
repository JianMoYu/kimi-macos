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
    case session = "会话"
    case daily = "今日"
    case monthly = "本月"
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

// MARK: - 本地统计缓存（增量扫描）

/// 单条 usage 记录，字段精简以压缩缓存体积
struct UsageRecord: Codable {
    let t: Double   // 事件时间戳（毫秒）
    let s: String   // 所属 session id
    let io: Int     // 未缓存输入
    let icr: Int    // 缓存命中输入
    let icc: Int    // 缓存写入
    let o: Int      // 输出
}

/// 单个 wire.jsonl 的解析状态。记录 mtime/size 用于判断是否需要重新解析。
struct WireFileState: Codable {
    var mtime: Double
    var size: Int64
    var records: [UsageRecord]
}

/// 缓存文件整体结构。按文件分组存记录，
/// 便于文件被重写或轮转时按文件粒度丢弃旧记录重新解析。
struct StatsCache: Codable {
    static let currentVersion = 1
    var version: Int = StatsCache.currentVersion
    var updatedAt: Double = 0
    var files: [String: WireFileState] = [:]
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
    @Published public var monthlyStats: TokenStatGroup = TokenStatGroup()
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
    @Published public var currentSessionModel: String? = nil

    /// 每个 model ID → max_context_size 缓存（来自 /api/v1/models）
    /// session.usage.context_limit 服务端常返回 0（猜测是未初始化的占位），
    /// 侧边栏的 context 分母就需要从这个缓存兜底。
    /// 非 @Published：不参与 UI 重绘（只读缓存），避免每次轮询触发不必要的渲染。
    public var modelContextLimits: [String: Int] = [:]

    private var pollTimer: Timer? = nil
    private var speedDecayTimer: Timer? = nil
    private var lastInteractionNotified: String? = nil

    /// 全量扫描节流：recalculateCumulativeStats() 需遍历 ~/.kimi-code/sessions 下全部
    /// wire.jsonl（实测 46 文件 / 30MB ≈ 1.6s，且数据量随会话累积线性增长）。
    /// 进程内节流避免被 .onAppear、会话切换等高频事件反复触发；手动刷新走 force: true。
    /// 实测：命中缓存时一次完整扫描仅 ~33ms（46 文件仅做 stat 比对），
    /// 因此节流窗口可以压得很短，既省电又保证数字新鲜度。
    private var lastFullScanAt: Date? = nil
    private let fullScanThrottle: TimeInterval = 15.0

    public init() {
        startBackgroundSync()
        syncFromLatestSession()
        loadModelContextLimits()
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

        // 4b. usage.record 等帧带 model 字段 → 实时更新当前 session 的模型与 contextLimit
        // 不依赖 4s 轮询 /api/v1/sessions 的延迟。
        if let liveModel = obj["model"] as? String, !liveModel.isEmpty {
            self.currentSessionModel = liveModel
            if let limit = modelContextLimits[liveModel], limit > 0, self.contextLimit != limit {
                self.contextLimit = limit
            }
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

        // 累积统计（会话 / 今日 / 本月）统一由 recalculateCumulativeStats() 从本地缓存聚合得出。
        // 此处不再实时累加：实时流无法判断自然月归属，且与缓存聚合结果会双重计数。
        // 增量扫描后重算成本极低（未变动文件直接命中缓存），不影响数字新鲜度。
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
        // SubAgent 状态只在生命周期事件中更新：
        //   - step.begin / turn.prompt / prompt.accepted        → working
        //   - step.end / turn.ended / prompt.completed          → completed / failed
        // 其它带 agentId 的帧（mcp.tools_discovered / runtime.set_binding / profile.bind /
        // token_counting.turn_recorded 等通告类事件）一律跳过。
        // 旧实现会把任何 agentId != main 的帧都 upsert 成 isBusy ? "working" : "idle"，
        // main agent 一旦还在跑，所有 sub-agent 都跟着显示"运行中"。
        if let agentId = obj["agentId"] as? String, agentId != "main" {
            let innerEvent = obj["event"] as? [String: Any]
            let effectiveType = (innerEvent?["type"] as? String) ?? eventType
            let normalized = effectiveType.lowercased()
            if normalized == "step.begin" || normalized == "turn.prompt" || normalized == "prompt.accepted" {
                upsertSubAgent(id: agentId, status: "working")
            } else if normalized == "step.end" || normalized == "turn.ended" || normalized == "prompt.completed" {
                let reason = (innerEvent?["reason"] as? String) ?? (obj["reason"] as? String)
                upsertSubAgent(id: agentId, status: reason == "failed" ? "failed" : "completed")
            }
            // 其它 lifecycle 事件忽略；syncSessionDiskState 会每 4s 兜底重读 wire.jsonl
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

    /// 从 /api/v1/models 拉取 model ID → max_context_size 映射。
    /// 用于补 session.usage.context_limit 缺失的情况（kimi server 实测常返回 0）。
    /// 网络失败时静默保留旧缓存，下次 syncFromLatestSession 触发后会自动重试。
    public func loadModelContextLimits() {
        let port = KimiServiceManager.shared.port
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/v1/models") else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 2.0
        if let token = KimiServiceManager.shared.fetchServerToken(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self = self,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = (json["data"] as? [String: Any])?["items"] as? [[String: Any]]
                ?? (json["data"] as? [[String: Any]]) else {
                return
            }

            var mapping: [String: Int] = [:]
            for item in items {
                guard let model = item["model"] as? String,
                      let limit = item["max_context_size"] as? Int,
                      limit > 0 else { continue }
                mapping[model] = limit
            }

            DispatchQueue.main.async {
                self.modelContextLimits = mapping
                // 缓存就绪后，若当前已有绑定的 session，立即用模型分母修正 contextLimit
                if let model = self.currentSessionModel,
                   let limit = mapping[model],
                   self.contextLimit != limit {
                    self.contextLimit = limit
                }
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

        // 记录当前 session 的 model ID，用于 /api/v1/models 缓存就绪时回填 contextLimit
        let sessionModel = (session["agent_config"] as? [String: Any])?["model"] as? String
        self.currentSessionModel = sessionModel

        if let usage = session["usage"] as? [String: Any] {
            if let inTokens = usage["input_tokens"] as? Int, inTokens > 0 {
                applyUsageMetrics(usage)
            }
            if let ctx = usage["context_tokens"] as? Int, ctx > 0 {
                self.contextTokens = ctx
            }
            // context_limit 兜底链：
            // 1) usage.context_limit > 0（首选，但实测 kimi server 常返回 0 占位）
            // 2) session.agent_config.model → /api/v1/models 缓存的 max_context_size
            // 3) 都不命中：保持上次的 contextLimit（默认 262144，留给调用方观察）
            if let limit = usage["context_limit"] as? Int, limit > 0 {
                self.contextLimit = limit
            } else if let model = sessionModel, let limit = modelContextLimits[model], limit > 0 {
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
                    let agentHome = agentInfo["homedir"] as? String
                    let wireFile = agentHome.map { "\($0)/wire.jsonl" } ?? ""
                    // 每个 sub-agent 独立判断：扫它自己 wire.jsonl 末尾的 step / turn 事件，
                    // 不再跟随 main agent 的 isBusy。否则只要 main 还在工作，
                    // 已完成的 sub-agent 也会被全部显示为"运行中"。
                    let status = detectSubAgentLiveStatus(wireFile: wireFile)
                    discoveredSubAgents.append(SubAgentItem(
                        id: agentId,
                        name: name,
                        status: status,
                        parentId: parentId
                    ))
                }
            }

            let wireFile = "\(validSessionPath)/agents/main/wire.jsonl"
            self.readTailWireMetrics(filePath: wireFile)

            DispatchQueue.main.async {
                // 用 disk 上判定的真实状态覆盖运行时数组：
                // 1) 现有 sub-agent 但已不在本 session → 移除（切会话/被回收的残留）
                // 2) 现有 sub-agent 仍在 → 用 disk 真状态覆盖 status（disk 是 ground truth，
                //    修正 ws 帧未及时送达或 main agent busy 时的误判）
                // 3) 新出现 → append
                // 直接用 discovered 数组覆盖，避免残留旧 session 的 sub-agent
                self.subAgents = discoveredSubAgents
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

    /// 读取 sub-agent 自己的 wire.jsonl 末尾，判断它当前的运行状态。
    /// 决策依据：sub-agent 自身的最后一次生命周期事件，而非 main agent 的 isBusy。
    /// 状态机（按 wire.jsonl 中真实事件序列）：
    ///   - 文件不存在 / 为空                          → "idle"
    ///   - 最后一条是 step.begin/turn.prompt/prompt.accepted
    ///         且时间戳在 30s 内                      → "working"
    ///         否则（卡住/异常退出）                → "completed"
    ///   - 最后一条是 turn.ended / prompt.completed
    ///         reason=failed                         → "failed"
    ///         其它                                  → "completed"
    ///   - 最后一条是 step.end（无对应终态）         → "completed"
    ///   - 没有任何 step/turn/prompt 事件             → "idle"
    /// 调用方：syncSessionDiskState() 每 4s 兜底重读；wire 帧实时事件由
    /// handleAgentOrTaskEvent 单独处理（更快的实时更新）。
    private func detectSubAgentLiveStatus(wireFile: String) -> String {
        guard !wireFile.isEmpty,
              FileManager.default.fileExists(atPath: wireFile),
              let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: wireFile)) else {
            return "idle"
        }
        defer { try? handle.close() }

        let fileSize = handle.seekToEndOfFile()
        guard fileSize > 0 else { return "idle" }
        let readLength = min(fileSize, 16384)
        handle.seek(toFileOffset: fileSize - readLength)
        guard let text = String(data: handle.readDataToEndOfFile(), encoding: .utf8) else {
            return "idle"
        }

        // 从后往前找最近一条生命周期事件（顶层 type 或 wrap 在 event.type 里）
        var lastKind: String = ""   // "begin" / "end"
        var lastReason: String = ""
        var lastTime: Double = 0

        for line in text.components(separatedBy: "\n").reversed() {
            if line.isEmpty { continue }
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            let innerEvent = obj["event"] as? [String: Any]
            let rawType = (innerEvent?["type"] as? String) ?? (obj["type"] as? String) ?? ""
            let normalized = rawType.lowercased()

            if normalized == "step.begin" || normalized == "turn.prompt" || normalized == "prompt.accepted" {
                lastKind = "begin"
                lastTime = (obj["time"] as? Double) ?? 0
                break
            } else if normalized == "step.end" || normalized == "turn.ended" || normalized == "prompt.completed" {
                lastKind = "end"
                lastReason = (innerEvent?["reason"] as? String) ?? (obj["reason"] as? String) ?? ""
                lastTime = (obj["time"] as? Double) ?? 0
                break
            }
            // 其它事件类型（context.append_message / llm.request / mcp.tools_discovered 等）继续往前找
        }

        if lastKind == "begin" {
            // step.begin 之后长时间没 step.end → 视为已停止（兜底）
            if lastTime > 0 {
                let ageMs = Date().timeIntervalSince1970 * 1000.0 - lastTime
                if ageMs < 30_000 { return "working" }
            }
            return "completed"
        } else if lastKind == "end" {
            return lastReason == "failed" ? "failed" : "completed"
        }
        return "idle"
    }

    // MARK: - Token 统计（本地缓存 + 增量扫描）

    // 设计：缓存按 wire.jsonl 粒度记录 (mtime, size, 已解析记录)，
    // 只有新增或变动的文件才重新解析。聚合在内存中完成，因此切换维度无需重算。

    /// 缓存路径：~/Library/Application Support/Kimi/token-stats-cache.json
    private var statsCacheURL: URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                        in: .userDomainMask).first else { return nil }
        let dir = appSupport.appendingPathComponent("Kimi", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("token-stats-cache.json")
    }

    private func loadStatsCache() -> StatsCache {
        guard let url = statsCacheURL,
              let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(StatsCache.self, from: data),
              cache.version == StatsCache.currentVersion else {
            return StatsCache()
        }
        return cache
    }

    private func saveStatsCache(_ cache: StatsCache) {
        guard let url = statsCacheURL,
              let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// 解析单个 wire.jsonl，只抽取 usage.record（scope 为 turn）的精简字段
    private func parseWireFile(at path: String, sessionId: String) -> [UsageRecord] {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return [] }

        var records: [UsageRecord] = []
        // split(separator:) 产出 Substring，避免为每行创建独立 String 对象
        for line in text.split(separator: "\n") {
            guard line.contains("usage.record") else { continue }
            guard let lineData = String(line).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  obj["type"] as? String == "usage.record",
                  let usage = obj["usage"] as? [String: Any] else { continue }

            // 过滤非 turn 范围，防止与已聚合的 session 级记录重复计数
            if let scope = obj["usageScope"] as? String, scope != "turn" { continue }

            let t = (obj["time"] as? NSNumber)?.doubleValue ?? 0
            let io = usage["inputOther"] as? Int ?? usage["input_tokens"] as? Int ?? 0
            let icr = usage["inputCacheRead"] as? Int ?? usage["cache_read_input_tokens"] as? Int ?? 0
            let icc = usage["inputCacheCreation"] as? Int ?? usage["cache_creation_input_tokens"] as? Int ?? 0
            let o = usage["output"] as? Int ?? usage["output_tokens"] as? Int ?? 0
            records.append(UsageRecord(t: t, s: sessionId, io: io, icr: icr, icc: icc, o: o))
        }
        return records
    }

    /// 按维度聚合缓存中的全部记录（会话 / 今日 / 本月）
    private func aggregate(_ cache: StatsCache) -> (sessionMap: [String: TokenStatGroup],
                                                    latestTimes: [String: Double],
                                                    today: TokenStatGroup,
                                                    monthly: TokenStatGroup) {
        let calendar = Calendar.current
        let todayComps = calendar.dateComponents([.year, .month, .day], from: Date())
        let monthComps = calendar.dateComponents([.year, .month], from: Date())

        var sessionMap: [String: TokenStatGroup] = [:]
        var latestTimes: [String: Double] = [:]
        var today = TokenStatGroup()
        var monthly = TokenStatGroup()

        for (_, state) in cache.files {
            for r in state.records {
                var g = sessionMap[r.s] ?? TokenStatGroup()
                g.add(inputOther: r.io, inputCacheRead: r.icr, inputCacheCreation: r.icc, output: r.o)
                sessionMap[r.s] = g

                if r.t > (latestTimes[r.s] ?? 0) { latestTimes[r.s] = r.t }

                let c = calendar.dateComponents([.year, .month, .day],
                                                from: Date(timeIntervalSince1970: r.t / 1000.0))
                if c.year == todayComps.year, c.month == todayComps.month, c.day == todayComps.day {
                    today.add(inputOther: r.io, inputCacheRead: r.icr, inputCacheCreation: r.icc, output: r.o)
                }
                if c.year == monthComps.year, c.month == monthComps.month {
                    monthly.add(inputOther: r.io, inputCacheRead: r.icr, inputCacheCreation: r.icc, output: r.o)
                }
            }
        }
        return (sessionMap, latestTimes, today, monthly)
    }

    public func recalculateCumulativeStats(force: Bool = false) {
        // 调用方均在主线程（init / didSet / .onAppear / Button action），此处直接读写节流状态
        if !force, let last = lastFullScanAt, Date().timeIntervalSince(last) < fullScanThrottle {
            return
        }
        lastFullScanAt = Date()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let sessionsDir = "\(home)/.kimi-code/sessions"
            guard FileManager.default.fileExists(atPath: sessionsDir),
                  let enumerator = FileManager.default.enumerator(atPath: sessionsDir) else { return }

            var cache = self.loadStatsCache()
            var seen = Set<String>()
            var changed = false

            while let relPath = enumerator.nextObject() as? String {
                guard relPath.hasSuffix("wire.jsonl") else { continue }
                let fullPath = "\(sessionsDir)/\(relPath)"
                seen.insert(fullPath)

                // 从相对路径中提取 sessionId（包含 session_ 的目录名）
                var sid: String? = nil
                for part in relPath.split(separator: "/") where part.hasPrefix("session_") {
                    sid = String(part)
                    break
                }
                guard let validSid = sid else { continue }

                guard let attrs = try? FileManager.default.attributesOfItem(atPath: fullPath),
                      let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970,
                      let size = attrs[.size] as? Int64 else { continue }

                // 命中缓存：mtime 与 size 均未变 → 跳过解析
                if let cached = cache.files[fullPath],
                   cached.size == size, abs(cached.mtime - mtime) < 0.5 {
                    continue
                }

                cache.files[fullPath] = WireFileState(
                    mtime: mtime,
                    size: size,
                    records: self.parseWireFile(at: fullPath, sessionId: validSid)
                )
                changed = true
            }

            // 清理已删除的会话文件
            let removed = Set(cache.files.keys).subtracting(seen)
            if !removed.isEmpty {
                for key in removed { cache.files.removeValue(forKey: key) }
                changed = true
            }

            if changed {
                cache.updatedAt = Date().timeIntervalSince1970
                self.saveStatsCache(cache)
            }

            let (sessionMap, latestTimes, today, monthly) = self.aggregate(cache)

            // 当前会话：优先已绑定的，未绑定时取最近有交互记录的会话
            var activeSid = self.currentSessionId
            if activeSid == nil, let latest = latestTimes.max(by: { $0.value < $1.value })?.key {
                activeSid = latest
            }
            let finalActiveSid = activeSid
            let finalSessionStat = (finalActiveSid != nil ? sessionMap[finalActiveSid!] : nil) ?? TokenStatGroup()

            DispatchQueue.main.async {
                if self.currentSessionId == nil, finalActiveSid != nil {
                    self.currentSessionId = finalActiveSid
                }
                self.sessionStatsMap = sessionMap
                self.sessionStats = finalSessionStat
                self.todayStats = today
                self.monthlyStats = monthly
            }
        }
    }
}
