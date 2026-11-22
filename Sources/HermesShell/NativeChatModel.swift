#if canImport(SwiftUI)
import SwiftUI
#else
import Foundation
#endif

/// 纯策略，不依赖 UIKit/SwiftUI：仅当本次发送已受理且无错误、结果确定时才清空附件。
/// 被 guard 拒绝的重复发送（accepted == false）应保留附件供用户重试；结果不确定
/// （uncertain）或有错误时同样保留。
enum AttachmentResetPolicy {
    static func shouldReset(accepted: Bool, hasError: Bool, uncertain: Bool) -> Bool {
        accepted && !hasError && !uncertain
    }
}

/// 本轮正在跑时，新输入怎么处理。服务端三种语义都支持，默认 steer。
enum ChatSendMode: String, CaseIterable, Identifiable {
    /// 不打断当前轮，在下一个工具结果边界注入（对应 /api/chat/steer）。
    case steer
    /// 本轮跑完后自动发出。
    case queue
    /// 先停掉当前轮，再作为新消息发出。
    case interrupt

    var id: String { rawValue }

    var label: String {
        switch self {
        case .steer: return "引导"
        case .queue: return "排队"
        case .interrupt: return "打断"
        }
    }

    var icon: String {
        switch self {
        case .steer: return "arrow.turn.down.right"
        case .queue: return "text.append"
        case .interrupt: return "stop.circle"
        }
    }

    /// 输入栏按钮的无障碍说明：这里要讲清「会不会打断」。
    var hint: String {
        switch self {
        case .steer: return "当前回复继续跑，你的话在下一个工具结果处插进去"
        case .queue: return "等这轮回复结束再自动发出去"
        case .interrupt: return "立刻停掉这轮回复，然后发送"
        }
    }
}

/// 「发送结果未确认」的只读核对结论。只有 `.absent`（后台历史里确认没有这条）
/// 才允许重发：`.delivered` 说明服务端已受理，重发会重复执行工具调用；
/// `.failed` 说明核对本身没完成，任何重发都必须继续锁住。

/// 一条等待用户决定的审批请求。
///
/// 网关把 run 挂在 `waiting_for_approval` 上、SSE 不断开，所以这张卡片出现时
/// 本轮并没有结束；不回答的话任务会一直停在这儿。可选项由服务端给（两项或四项），
/// 客户端不猜——不同场景下 `session` / `always` 未必允许。
struct ChatPendingApproval: Identifiable, Equatable {
    let id: String
    let runID: String
    let requestID: String?
    /// The server's execution generation, required for canonical approval POST.
    let executionGeneration: Int
    let detail: String
    let command: String?
    let choices: [String]

    /// 解析一张审批帧。服务端两种形态都见过：WebUI 的 `question`/`description`，
    /// 网关的 `message` + `choices`。解析失败返回 nil，调用方退回到普通提示，
    /// 绝不能让一张看不懂的卡片占着屏幕。
    static func make(from frame: SSEFrame, runID: String?) -> ChatPendingApproval? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(frame.data.utf8)))
                as? [String: Any] else { return nil }
        let detail = ["message", "description", "question", "command"]
            .compactMap { object[$0] as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let detail else { return nil }
        guard let requestID = (object["request_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !requestID.isEmpty,
              let generation = object["execution_generation"] as? Int,
              generation >= 0, let runID, !runID.isEmpty else { return nil }
        let allowed: Set<String> = ["once", "deny", "reject", "cancel"]
        let rawChoices = (object["choices"] as? [Any])?
            .compactMap { $0 as? String }
            .filter { !$0.isEmpty && allowed.contains($0.lowercased()) } ?? []
        // Neither a missing request identity nor absent server-provided choices
        // is an actionable approval. Never invent a grant from a partial SSE.
        var seenChoices = Set<String>()
        let choices = rawChoices.filter { seenChoices.insert($0).inserted }
        guard !choices.isEmpty else { return nil }
        let command = (object["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ChatPendingApproval(
            id: requestID, runID: runID, requestID: requestID,
            executionGeneration: generation,
            detail: detail,
            command: command?.isEmpty == true ? nil : command,
            choices: choices)
    }
}

enum PendingReconcileResult: Equatable {
    case delivered
    case absent
    case failed
}

@MainActor
final class NativeChatModel: ObservableObject {
    // 这些状态分散在 `NativeChatModel+Send/Stream/Control` 三个扩展文件里被写入。
    // Swift 的 `private(set)` 只允许同文件写入，跨文件就会编译失败；而 `internal(set)`
    // 在 internal 类型上又是冗余修饰符（本工程开了 warnings-as-errors）。
    // 因此统一用默认访问级别：读取对外可见（视图需要），写入收敛在模块内。
    // 真正的外部隔离由「类型本身不导出到模块外」保证，不是靠 setter 修饰符。
    @Published var transcript = ChatTranscript()

    /// 唯一可变真相。**所有迁移必须走 `transition(to:)`**，不要直接赋值：
    /// 那是唯一能挂上合法性断言的地方。下面的 `loading` / `running` / `syncing` …
    /// 都是它的派生只读视图，保留它们是为了让 67 处读取点与既有断言不必改写。
    @Published var phase: ChatPhase = .idle

    @Published var completedReplies: UInt = 0
    /// Sticky per chat page: once a recovery write fails, keep the limitation
    /// visible until the page is recreated. The backend flag itself may flip
    /// back after a later successful write; that does not make the failed run
    /// recoverable after relaunch.
    @Published var runRecoveryNoticeShown = false
    /// 后端声明这段历史只读（联网核对完成前也一律只读）。与相位正交。
    @Published var readOnly = true
    /// POST 结果待核对。与相位正交：可以一边跑新一轮一边留着上一笔待核对。
    @Published var uncertain = false
    /// 已离开会话页，连接暂停。**不代表本轮结束**——服务端那一轮仍在跑，
    /// 所以这是与相位正交的独立事实，不能塞进枚举。
    @Published var suspended = false
    /// 有一次 GET 归核对流程所有（`reconcilePending`）。与相位正交：
    /// 那次 GET 自身会走 `.syncing`，「核对中」和「同步中」必须同时成立。
    @Published var reconciling = false

    // MARK: - 派生状态（只读，不可赋值）

    /// 首次加载/前台恢复，界面显示整页占位。
    var loading: Bool { phase.isLoading }
    /// 静默同步历史（含「显示磁盘历史的同时在联网核对」）。
    var syncing: Bool { phase.isSyncing }
    /// 本轮未结束：提交中 / 流式中 / 重连中 / 停止中。
    var running: Bool { phase.isRunning }
    /// 流已收到帧。只有 `.streaming` 能携带这个信息。
    var streamConnected: Bool { phase.isConnected }
    var stopping: Bool { phase == .stopping }
    var submitting: Bool { phase == .submitting }
    var reconnecting: Bool { phase == .reconnecting }
    var authenticationRequired: Bool { phase == .needsLogin }
    /// 磁盘历史的时间戳；非 nil 表示当前显示的是本地缓存、尚未联网核对。
    var cachedHistoryDate: Date? { phase.cachedSince }

    /// 正交事实的打包视图，供 `ChatPhase` 的谓词统一消费。
    var facts: ChatFacts {
        ChatFacts(readOnly: readOnly, uncertain: uncertain || pendingRecoveryUnreadable || activeRecoveryUnreadable
                  || (activeTurnRecovery != nil && !phase.isRunning), suspended: suspended,
                  reconciling: reconciling, hasPendingSend: pendingSend != nil,
                  pendingAbsent: pendingAbsent, sendingWhileRunning: sendingWhileRunning)
    }

    /// 迁移到新相位。**所有相位变化都必须走这里**：这是唯一能挂断言的地方。
    /// 用 `assert` 而非 `precondition`：接线错误在 debug/离线测试里炸出来，
    /// release 构建不因为一个断言把用户界面打死。
    func transition(to next: ChatPhase) {
        guard phase != next else { return }
        assert(ChatPhase.isPlausibleTransition(from: phase, to: next),
               "implausible chat phase transition \(phase) -> \(next)")
        phase = next
    }

    /// Observe the backend after every operation that can write a run record.
    /// This never blocks sending: the current process still has the correct
    /// in-memory run ID and must not duplicate the POST.
    func noteRunRecoveryState() {
        guard api.runRecoveryUnavailable else { return }
        guard !runRecoveryNoticeShown else { return }
        runRecoveryNoticeShown = true
        RuntimeLogRecorder.shared.record(.warning, "recovery",
            "run record persistence unavailable; relaunch recovery degraded")
    }

    @Published var olderOffset = 0
    /// True once a whole older page no longer fits the data budget. The cursor
    /// stays put, so the range is never skipped; UI explains how to read it.
    @Published var olderLimitReached = false
    /// Older immutable history can load while the agent is streaming. Only
    /// conflicting submission, reconciliation, or ambiguous delivery locks it.
    var canLoadOlderHistory: Bool {
        cachedHistoryDate == nil && olderOffset > 0 && !olderLimitReached && !loadingOlder
            && !loading && !syncing && !submitting && !stopping
            && !reconciling && !uncertain && !suspended
    }
    @Published var error: String?
    @Published var notice: String?
    /// 本轮是以斜杠命令发起的（`/compress` 等）。
    ///
    /// 命令由服务端 agent 解释，客户端只负责原样转发。保留这份识别结果是为了在
    /// 服务端没有任何可见回应时补一条说明，避免用户误以为命令静默失败。
    /// 不发布：它只影响收尾时的一句提示，不参与界面求值。
    var pendingSlashCommand: ChatSlashCommand.Match?
    /// 仅当 `reconcilePending()` 用后台历史确认「没有这条」后才为 true。
    /// 视图据此才开放重发入口；其余时候必须保持锁定。
    @Published var pendingAbsent = false
    /// 当前挂起的审批请求。同一 run 可以同时有多个 requestID；按到达顺序
    /// 全部保留，重复帧按 `id` 原位更新，不能互相覆盖。
    @Published var pendingApprovals: [ChatPendingApproval] = []
    /// Compatibility with existing single-slot readers. New UI code must render
    /// the full array so an older request is never hidden behind a newer one.
    var pendingApproval: ChatPendingApproval? { pendingApprovals.last }
    /// 审批到达时的外部通知钩子。
    ///
    /// 模型不认识 `AppState`，也不该认识：投递与否由上层决定（开关、前台抑制、
    /// 会话标题都在那里）。这里只把「哪个会话、哪个请求」交出去。
    var onApprovalArrived: ((_ sessionID: String, _ requestID: String?) -> Void)?
    /// Exact request resolution, used to remove its delivered/pending
    /// notification. This is intentionally separate from arrival: a page may
    /// observe the resolution after its account scope is no longer current.
    var onApprovalResolved: ((_ sessionID: String, _ requestID: String?) -> Void)?
    /// 正在回传审批，按钮期间禁用，避免连点发两次。
    @Published var approving = false
    var approvalSubmission = UUID()
    /// 当前挂起的补充信息请求。非 nil 时界面显示输入卡片，agent 停在服务端等答复。
    /// 与 `pendingApproval` 可以同时存在（一次执行里可能先问一句再要审批），
    /// 所以不能用同一个字段复用。
    @Published var pendingClarifies: [ChatPendingClarify] = []
    /// Compatibility with existing single-slot readers; newest request first
    /// for callers that still use the legacy accessor.
    var pendingClarify: ChatPendingClarify? { pendingClarifies.last }
    /// clarify 到达时的外部通知钩子（与审批同一套投递链路）。
    var onClarifyArrived: ((_ sessionID: String, _ requestID: String?) -> Void)?
    var onClarifyResolved: ((_ sessionID: String, _ requestID: String?) -> Void)?
    /// 正在回传补充信息，输入框/按钮期间禁用。
    @Published var clarifying = false
    var clarifySubmission = UUID()
    /// 每次 `stop()` 提交的身份。旧提交的 `defer` 不能收尾更新的 `.stopping`。
    var stopSubmission = UUID()
    /// One settled send at a time; the view removes only these uploaded refs.
    @Published var settledAttachmentPaths: [String] = []
    @Published var draft = "" {
        didSet {
            guard let result = draftStore?.save(draft) else { return }
            // The composer already reports its verified debounced writes. A
            // model-side save is a fallback; only its failure is sticky.
            if !result.succeeded { recordLocalWrite(result, kind: .draft) }
        }
    }
    @Published var streamID: String?
    /// 会话当前模型（来自历史快照），用于输入栏显示真实标签。
    @Published var sessionModel: String?
    @Published var sessionProvider: String?
    @Published private(set) var requestedReasoningEffort: String?
    private var reasoningPreferenceKey: String {
        ReasoningEffortPolicy.preferenceKey(scope: displayScope, sessionID: sessionID)
    }
    /// Persist a local per-session preference, not a global Hermes setting.
    func chooseReasoningEffort(_ effort: String?) {
        guard api.supportsReasoningEffort, ReasoningEffortPolicy.allowed(effort) else { return }
        requestedReasoningEffort = effort
        if let effort { UserDefaults.standard.set(effort, forKey: reasoningPreferenceKey) }
        else { UserDefaults.standard.removeObject(forKey: reasoningPreferenceKey) }
    }
    /// 本轮思考过程。单独存放，绝不拼进正文，避免污染 Markdown 与复制内容。
    @Published var reasoning: String = ""
    let sessionID: String
    let api:NativeChatService
    var onAuthenticationRequired: (() -> Void)?
    let draftStore:ChatDraftStore?
    let historyStore:ChatHistoryStore?
    var historyReadAttempted = false
    var confirmedHistory:ChatHistoryRecord?
    var confirmedHistoryEnd: Int?
    /// Boundary captured BEFORE the latest POST. Build166 restores it from
    /// ActiveTurnRecovery on relaunch; missing evidence remains inconclusive.
    var activeTurnHistoryBoundary: Int?
    var activeTurnRecovery: ActiveTurnRecovery?
    /// Latest authoritative tail, retained only for bounded read-only recovery.
    /// Older verification pages are never inserted into the visible transcript.
    var latestRecoverySnapshot: ChatSnapshot?
    @Published var activeRecoveryUnreadable = false
    var authenticationReported = false
    var streamTask: Task<Void,Never>?
    /// One bounded receipt probe per receipt/page. The task is cancelled by
    /// disconnect or a newer load, and only `.alive` can attach the run.
    var activeRunProbeTask: Task<Void,Never>?
    var activeRunProbeRunID: String?
    /// A single bounded, read-only recovery owner for uncertain sends/runs.
    /// It never submits a chat POST or resumes a user-paused queue.
    var automaticReconciliationTask: Task<Void, Never>?
    var automaticReconciliationTicket: UUID?
    var automaticReconciliationDelaysNanoseconds: [UInt64] = [
        2_000_000_000, 5_000_000_000, 10_000_000_000,
        20_000_000_000, 40_000_000_000, 60_000_000_000
    ]
    /// A bounded read-only follow-up after any STOP attempt with no verified
    /// terminal result. Polling never sends a second STOP or chat POST.
    var stopStatusPollTask: Task<Void, Never>?
    var stopStatusPollTicket: UUID?
    var stopStatusProbeInFlight = false
    /// A 2xx response acknowledges the request, not completion. A 404/409 is
    /// a rejected request and must never be presented as a successful stop.
    var stopAcknowledged = false
    var stopRejectedStatusCode: Int?
    var stopStatusPollDelaysNanoseconds: [UInt64] = [
        1_000_000_000, 2_000_000_000, 4_000_000_000, 8_000_000_000,
        15_000_000_000, 30_000_000_000, 60_000_000_000, 60_000_000_000
    ]
    var buffer = ChatTranscript()
    var publishTask:Task<Void,Never>?
    var loadingOlder = false
    var lastEventID: String?
    var revision:UInt = 0
    var resumeRequested = false

    func runContext(for runID: String, generation: UInt) -> ChatRunContext {
        ChatRunContext(instanceScope: displayScope, sessionID: sessionID,
                       runID: runID, revision: generation)
    }

    func accepts(_ context: ChatRunContext) -> Bool {
        context.matches(instanceScope: displayScope, sessionID: sessionID,
                        runID: streamID, revision: revision, suspended: suspended)
    }
    /// 运行中发送的语义；默认 steer，与 WebUI 的 `default_message_mode` 一致。
    @Published var sendMode: ChatSendMode = .steer
    /// Complete turns waiting behind the active response. A bounded list keeps
    /// follow-up work visible without allowing unbounded local memory growth.
    @Published var queuedTurns: [ChatQueuedTurn] = []
    /// Runtime-only editor lease. No dispatch, reorder or delete while the
    /// user is editing a queued turn. It is not an implicit user-pause toggle.
    @Published var queueEditingTurnID: String?
    /// Restored or explicitly paused queues never auto-dispatch until the user
    /// resumes them. This protects an unsent turn across relaunch/cancellation.
    @Published var queueAutomaticDispatchPaused = false
    /// User intent and failure safety are separate; the effective UI flag is derived.
    @Published var queueUserPaused = false
    @Published var queueRecoveryPaused = false

    func updateQueuePause() {
        queueAutomaticDispatchPaused = queueUserPaused || queueRecoveryPaused
    }

    func pauseQueueForRecovery() {
        queueRecoveryPaused = true
        updateQueuePause()
    }

    func resumeQueueAfterRecovery() {
        queueRecoveryPaused = false
        updateQueuePause()
    }
    /// First queued turn, retained for compatibility with the single-slot UI.
    var queuedText: String? { queuedTurns.first?.summary }
    /// A-11：排队内容序列化失败时置位。此时最新排队项只在内存里，
    /// 重启 App 会丢，界面需要明确告知而不是假装已经持久化。
    @Published var queueSaveFailed = false
    /// P0：批量清空被拒绝时的原因（例如有消息正在提交）。
    ///
    /// 不静默丢弃在途记录，就必须让用户知道「为什么没清掉」，否则按钮点了
    /// 没反应会被当成卡死。成功清空时置回 nil。
    @Published var queueClearRefusal: String?
    /// Sticky for this chat page: a verified local write failed at least once.
    /// The value contains only a category and timestamp, never content or IDs.
    @Published var localPersistenceIssue: LocalDataIssue?
    /// A file-write failure also feeds the legacy queue flag for the queue UI.
    /// Keep that derived mirror in sync so every entry point shows the same
    /// sticky state, including the composer and queue manager.
    var queuePersistenceFailed: Bool {
        queueSaveFailed || localPersistenceIssue?.kind == .queue
    }
    @Published var sendingWhileRunning = false
    /// Data window for paged history. Kept independent from the mounted-host
    /// budget: pages are accepted or refused as a whole, never trimmed after
    /// prepending. Trimming the oldest rows right after inserting a page used to
    /// delete the very page just fetched while `olderOffset` still advanced.
    /// 冷启动预热窗口：从磁盘历史里只取最后 N 条先渲染。
    ///
    /// 与下面两个上限**语义不同、不是重复**：
    /// - `cachedWarmupMessages`（本常量，60）：冷启动首屏渲染窗口。只为「别在
    ///   第一次网络请求前挂上千个富文本行」，联网 GET 一到就被权威窗口替换。
    /// - `maxLoadedMessages`（2000）：**内存**数据窗口。分页累积的上限，超了拒收
    ///   整页（不是裁掉）。
    /// - `ChatHistoryStore.maxMessages`（1200）：**磁盘**保留窗口。决定下次冷启动
    ///   能预热多少。
    /// 三套各自独立，把任意两个合并都会破坏另一个的语义。
    static let cachedWarmupMessages = 60
    static let maxLoadedMessages = 2000
    /// Byte budget for the same window (ids + bodies + attachment references).
    static let maxLoadedBytes = 16 * 1024 * 1024
    /// 只有附件时服务端仍要求 message 非空；气泡里显示真实内容，正文用这个占位。
    /// 展示层用同一份定义判断是否隐藏，避免两处字符串漂移。
    static let attachmentOnlyText = ChatAttachmentPlaceholder.systemText
    /// 一次 POST 失败时的发送快照。仅用于「核对 / 重发 / 放弃」，
    /// 不参与发送结果判定；附件是服务端引用，重发时原样带回、不重新上传。
    struct PendingSend: Codable {
        let id: String
        let text: String
        let attachments: [ChatAttachmentPayload]
        let composerText: String
        let historyEnd: Int?
        let knownIDs: Set<String>
        let createdAt: Double
        /// 这条消息是用户输入的，还是系统为「只有附件」补的占位。
        /// 重发必须沿用同一次判定的结果，不能看最终文字重新推断。
        let origin: ChatSendOrigin
        /// Dismissing the provisional bubble cannot destroy POST evidence.
        /// Optional preserves decoding of durable records created by old builds.
        var hiddenFromTranscript: Bool? = nil

        func resolution(in snapshot: ChatSnapshot) -> PendingReconcileResult {
            DeliveryReconciliationPolicy.resolve(
                text: text, attachments: attachments, historyEnd: historyEnd,
                knownIDs: knownIDs, snapshot: snapshot)
        }
    }
    @Published var pendingRecoveryUnreadable = false

    func abandonUnreadablePending() {
        guard !submitting, !syncing, !loading else { return }
        let result = draftStore?.savePending(nil) ?? .ok
        guard result.succeeded else { recordLocalWrite(result, kind: .queue); return }
        pendingRecoveryUnreadable = false
        uncertain = true // A subsequent GET is still required.
        notice = "已放弃损坏的本地记录，请核对历史后再发送，避免重复提交。"
    }

    var pendingSend: PendingSend? {
        didSet {
            // Persist before POST and clear only when resolved or explicitly abandoned.
            let result = persistPendingSend()
            recordLocalWrite(result, kind: .queue)
        }
    }

    @discardableResult
    func persistPendingSend() -> LocalStoreWriteResult {
        guard !pendingRecoveryUnreadable else { return .failed(.corruptFile) }
        guard let draftStore else { return .ok }
        guard let pendingSend else { return draftStore.savePending(nil) }
        guard let data = try? JSONEncoder().encode(pendingSend) else { return .failed(.encoding) }
        return draftStore.savePending(data)
    }

    /// Write the accepted-run receipt BEFORE deleting the pre-POST PendingSend.
    /// On failure keep PendingSend durable and suppress automatic queue dispatch.
    @discardableResult
    func rememberAcceptedTurn(runID: String, text: String,
                              attachments: [ChatAttachmentPayload],
                              knownIDs: Set<String>) -> Bool {
        let receipt = ActiveTurnRecovery(
            runID: runID, historyEnd: activeTurnHistoryBoundary,
            knownIDs: knownIDs, text: text,
            attachmentPaths: Set(attachments.map(\.path)))
        guard let data = try? JSONEncoder().encode(receipt) else {
            recordLocalWrite(.failed(.encoding), kind: .runRecovery)
            return false
        }
        let result = draftStore?.saveActiveRun(data) ?? .ok
        guard result.succeeded else {
            recordLocalWrite(result, kind: .runRecovery)
            return false
        }
        activeTurnRecovery = receipt
        return true
    }

    /// A clear is authoritative only after its protected-file removal succeeds.
    /// Failed removal must not silently erase recovery evidence from memory.
    @discardableResult
    func clearAcceptedTurnRecovery() -> Bool {
        guard activeTurnRecovery != nil else { return true }
        activeRunProbeTask?.cancel()
        activeRunProbeTask = nil
        activeRunProbeRunID = nil
        let result = draftStore?.saveActiveRun(nil) ?? .ok
        guard result.succeeded else {
            recordLocalWrite(result, kind: .runRecovery)
            uncertain = true
            return false
        }
        activeTurnRecovery = nil
        activeTurnHistoryBoundary = nil
        return true
    }

    /// Explicit user override, never called by automatic retry or queue flush.
    /// Keep the queue paused and require a fresh authoritative GET afterwards.
    func abandonAcceptedTurnRecovery() {
        guard !submitting, !loading, !syncing, !running, !reconciling else { return }
        guard clearAcceptedTurnRecovery() else { return }
        pauseQueueForRecovery()
        uncertain = true
        notice = "已放弃本地运行恢复标记；没有重发消息。请重新核对服务端历史后再继续。"
    }

    func abandonUnreadableActiveRecovery() {
        guard !submitting, !loading, !syncing, !running, !reconciling else { return }
        let result = draftStore?.saveActiveRun(nil) ?? .ok
        guard result.succeeded else { recordLocalWrite(result, kind: .runRecovery); return }
        activeRecoveryUnreadable = false
        pauseQueueForRecovery()
        uncertain = true
        notice = "已放弃损坏的运行记录；请先核对历史，不会自动重发或继续队列。"
    }

    // The start API returns a stream ID, not a canonical user-message receipt,
    // so the server row is identified afterwards from the authoritative window.
    // The match must be UNIQUE: two equally plausible rows mean no binding, and
    // the text stays visible. Nothing is inferred from time or ordering.

    /// 一次「空正文 + 附件」发送的确认条件。发送时记下，快照到达后消费一次。
    struct PlaceholderCandidate {
        let localID: String
        /// 本次 POST 之前的原始历史边界；只有它之后的新行才可能是这次发送。
        let historyEnd: Int?
        /// 发送前已存在的消息 ID，用来排除旧回声。
        let knownIDs: Set<String>
        let text: String
        let attachmentPaths: Set<String>
    }
    var placeholderCandidates: [PlaceholderCandidate] = []

    /// 能发起新的一轮。运行中为 false —— 那时走 `canSendWhileRunning` 的三条追加路径。
    /// 派生逻辑集中在 `ChatPhase`，这里只负责把正交事实打包传进去。
    var canSend: Bool { phase.allowsNewTurn(facts) }
    /// 本轮正在跑时，是否还能把这条发出去（steer / queue / interrupt 三条路径之一）。
    /// `running` 不再直接锁死输入栏：Hermes 支持运行中引导，客户端不该比服务端更保守。
    /// 但 `.reconnecting` 一律不放行——重连期间服务端没有活跃 agent 可注入。
    var canSendWhileRunning: Bool { phase.allowsSteer(facts) }

    /// 只有在核对确认后台不存在这条之后才允许重发。
    var canResendPending: Bool { phase.allowsResend(facts) }

    var hasPendingSend: Bool { pendingSend != nil }

    /// Apply the exact identity acknowledged by a model-change request. A
    /// provider-only change does not change SessionSummary.model's string.
    func setConfirmedModel(_ model: String, provider: String?) {
        if sessionModel != model || sessionProvider != provider {
            chooseReasoningEffort(nil)
        }
        sessionModel = model
        sessionProvider = provider
    }

    /// 界面状态。优先级即顺序，与重构前逐条一致（既有断言依赖这个顺序）。
    /// 相位只回答「在做什么」，正交事实（登录失效/暂停/核对）由这里按优先级
    /// 覆盖——它们能盖过相位，因为对用户来说它们是更强的信息。
    var activity: ChatActivity {
        if case .needsLogin = phase { return .needsLogin }
        if case .stopping = phase { return .stopping }
        if case .submitting = phase { return .sending }
        if suspended { return .suspended }
        if case .cached(_, let syncing) = phase { return .cached(syncing: syncing) }
        if case .loading = phase { return .loading }
        if case .reconnecting = phase { return .reconnecting }
        if reconciling { return .verifying }
        if case .syncing = phase { return .syncing }
        if uncertain || pendingSend != nil || (activeTurnRecovery != nil && !phase.isRunning) {
            return .needsVerification
        }
        if readOnly { return .readOnly }
        if case .streaming(let connected) = phase {
            // A live turn outranks a leftover error string: the stream may still
            // recover, and "操作未完成" would contradict the running spinner.
            if !connected { return .connecting }
            let active = ChatActivity.activeToolIDs(messages: buffer.messages, tools: buffer.tools)
            if let tool = buffer.tools.last(where: { active.contains($0.id) }) { return .tool(tool.name) }
            return .replying
        }
        if error != nil { return .failed }
        return .ready
    }

    /// 实例 + 账号作用域，仅用于本机「纯图占位」标记；空串表示不记录（测试或未接线）。
    let displayScope: String

    init(sessionID:String,api:NativeChatService,draftStore:ChatDraftStore? = nil,
         historyStore:ChatHistoryStore? = nil, displayScope:String = "") {
        self.sessionID = sessionID
        self.api = api
        self.draftStore = draftStore
        self.historyStore = historyStore
        self.displayScope = displayScope
        if api.supportsReasoningEffort {
            requestedReasoningEffort = ReasoningEffortPolicy.validated(
                UserDefaults.standard.string(forKey:
                    ReasoningEffortPolicy.preferenceKey(scope: displayScope, sessionID: sessionID)))
        }
        let loadedDraft = draftStore?.loadDraftResult()
        self.draft = loadedDraft?.value ?? ""
        if let issue = loadedDraft?.result.failure {
            localPersistenceIssue = LocalDataIssue(kind: .draft, failure: issue, observedAt: Date())
            RuntimeLogRecorder.shared.record(.warning, "local-store",
                "persistence degraded kind=draft reason=\(issue.rawValue)")
        }
        let restored = draftStore?.loadPending()
        if let data = restored?.value {
            if let pending = try? JSONDecoder().decode(PendingSend.self, from: data) {
                pendingSend = pending
                uncertain = true
                if pending.hiddenFromTranscript != true {
                    buffer.messages = [ChatMessage(id: pending.id, role: "user", content: pending.text,
                        timestamp: pending.createdAt, sourceIndex: nil,
                        attachmentPaths: pending.attachments.map(\.path), delivery: .unconfirmed)]
                    transcript = buffer
                }
                notice = "上次发送结果待核对，核对前不会自动重发。"
            } else {
                uncertain = true
                pendingRecoveryUnreadable = true
                localPersistenceIssue = LocalDataIssue(kind: .queue, failure: .corruptFile, observedAt: Date())
            }
        } else if let failure = restored?.result.failure {
            pendingRecoveryUnreadable = true
            uncertain = true
            localPersistenceIssue = LocalDataIssue(kind: .queue, failure: failure, observedAt: Date())
        }
        let restoredActive = draftStore?.loadActiveRun()
        if let data = restoredActive?.value {
            if let receipt = try? JSONDecoder().decode(ActiveTurnRecovery.self, from: data) {
                activeTurnRecovery = receipt
                activeTurnHistoryBoundary = receipt.historyEnd
                if pendingSend == nil {
                    uncertain = true
                    notice = "上次已受理的后台任务正在核对；不会重复提交消息。"
                }
            } else {
                activeRecoveryUnreadable = true
                uncertain = true
                localPersistenceIssue = LocalDataIssue(
                    kind: .runRecovery, failure: .corruptFile, observedAt: Date())
            }
        } else if let failure = restoredActive?.result.failure {
            activeRecoveryUnreadable = true
            uncertain = true
            localPersistenceIssue = LocalDataIssue(
                kind: .runRecovery, failure: failure, observedAt: Date())
        }
        queueUserPaused = draftStore?.loadQueueUserPaused() ?? false
        updateQueuePause()
        let loadedQueue = draftStore?.loadQueuedResult()
        if let data = loadedQueue?.value {
            queuedTurns = ChatQueueOrdering.prioritize(ChatSendQueueCodec.decode(data) ?? [])
            // A process can die while a queue POST is in flight. Do not retry
            // it on relaunch; surface it as uncertain until the user acts.
            for index in queuedTurns.indices
            where queuedTurns[index].delivery == .submitting {
                queuedTurns[index].delivery = .uncertain
                queuedTurns[index].automaticAfterStreamID = nil
            }
            queueRecoveryPaused = !queuedTurns.isEmpty
            updateQueuePause()
        }
        if let issue = loadedQueue?.result.failure {
            if localPersistenceIssue == nil {
                localPersistenceIssue = LocalDataIssue(kind: .queue, failure: issue, observedAt: Date())
            }
            RuntimeLogRecorder.shared.record(.warning, "local-store",
                "persistence degraded kind=queue reason=\(issue.rawValue)")
        }
    }

    /// Record only the failure category and time. Message text, identifiers,
    /// endpoints and paths never enter this state or its diagnostics.
    func recordLocalWrite(_ result: LocalStoreWriteResult?,
                          kind: LocalDataKind, observedAt: Date = Date()) {
        guard let failure = result?.failure else { return }
        localPersistenceIssue = LocalDataIssue(kind: kind, failure: failure, observedAt: observedAt)
        if kind == .queue { queueSaveFailed = true }
        RuntimeLogRecorder.shared.record(.warning, "local-store",
            "persistence degraded kind=\(kind.rawValue) reason=\(failure.rawValue)")
    }

    /// A successful explicit retry for the same data kind clears only that
    /// kind's sticky issue. Ordinary typing does not call this: an earlier
    /// failed write remains visible until the recovery center proves recovery.
    func recordVerifiedLocalRetry(_ result: LocalStoreWriteResult, kind: LocalDataKind) {
        if result.succeeded {
            if localPersistenceIssue?.kind == kind {
                localPersistenceIssue = nil
            }
            if kind == .queue { queueSaveFailed = false }
        } else {
            recordLocalWrite(result, kind: kind)
            if kind == .queue { queueSaveFailed = true }
        }
    }

    /// A successful ordinary write for this kind clears a previous issue of
    /// that kind. Other kinds remain independent. The composer calls this only
    /// after a verified write; a model-side no-op save is not evidence of a
    /// durable write.
    func recordSuccessfulLocalWrite(kind: LocalDataKind) {
        if localPersistenceIssue?.kind == kind {
            localPersistenceIssue = nil
        }
        if kind == .queue { queueSaveFailed = false }
    }

    /// Retry a pending legacy migration without changing the current in-memory
    /// draft or queue. A successful verified migration clears its category.
    @discardableResult
    func retryLocalMigration() -> LocalStoreWriteResult {
        guard !pendingRecoveryUnreadable else { return .failed(.corruptFile) }
        guard let draftStore else { return .ok }
        let results = draftStore.retryMigration()
        if results.draft.succeeded {
            if localPersistenceIssue?.kind == .draft { localPersistenceIssue = nil }
        } else { recordLocalWrite(results.draft, kind: .draft) }
        if results.queue.succeeded {
            if localPersistenceIssue?.kind == .queue { localPersistenceIssue = nil }
            queueSaveFailed = false
        } else {
            queueSaveFailed = true
            recordLocalWrite(results.queue, kind: .queue)
        }
        return results.draft.succeeded ? results.queue : results.draft
    }

    @discardableResult
    func validateLocalData() -> LocalStoreWriteResult {
        guard !pendingRecoveryUnreadable && !activeRecoveryUnreadable else {
            return .failed(.corruptFile)
        }
        guard let draftStore else { return .ok }
        let migration = draftStore.retryMigration()
        let validation = draftStore.validateStoredData()
        let migrationResult = migration.draft.succeeded ? migration.queue : migration.draft
        let result = migrationResult.succeeded ? validation : migrationResult
        if result.succeeded {
            localPersistenceIssue = nil
            queueSaveFailed = false
        } else {
            recordLocalWrite(result, kind: localPersistenceIssue?.kind ?? .draft)
        }
        return result
    }
}
