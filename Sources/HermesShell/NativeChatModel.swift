#if canImport(SwiftUI)
import SwiftUI
import Combine
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
struct ChatPendingApproval: Identifiable, Codable, Equatable, Sendable {
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
        ChatFacts(readOnly: readOnly, uncertain: uncertain || recoveryRecordsUnreadable
                  || (activeTurnRecovery != nil && !phase.isRunning), suspended: suspended || runtimeRetired,
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
        recordRuntimeLog(.warning, "recovery",
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

    func settleAcceptedAttachments(_ paths: [String]) {
        guard !runtimeRetired else { return }
        #if canImport(UIKit)
        if let result = draftStore?.consumeSettledAttachmentPaths(Set(paths), sessionID: sessionID) {
            if result.succeeded { recordSuccessfulLocalWrite(record: .attachmentDraft) }
            else { recordLocalWrite(result, record: .attachmentDraft) }
        }
        #endif
        settledAttachmentPaths = paths
    }
    @Published private(set) var draftRecoveryUnreadable = false
    @Published var draft = "" {
        didSet {
            guard !runtimeRetired, !draftRecoveryUnreadable else { return }
            guard let result = draftStore?.save(draft) else { return }
            // The composer already reports its verified debounced writes. A
            // model-side save is a fallback; only its failure is sticky.
            if !result.succeeded { recordLocalWrite(result, kind: .draft) }
        }
    }
    /// The composer owns newly typed text. A late receipt must not erase
    /// a newer persisted draft while this runtime is offscreen.
    func clearOriginalDraft(_ original: String) {
        guard !runtimeRetired, draft == original else { return }
        if let store = draftStore {
            let current = store.loadDraftResult()
            guard current.result.succeeded, current.value == original else { return }
        }
        draft = ""
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
    private(set) var runtimeRetired = false
    /// A cold offscreen owner may read history and attach SSE, but cannot
    /// dispatch an original turn or queued POST before a presentation claims it.
    var recoveryOnly = false
    var recoveryCheckpointRead = false
    var lastCheckpointWrite: TimeInterval = -.infinity
    private var checkpointEncodingTask: Task<Data?, Never>?
    private var checkpointEncodingTicket: UUID?

    /// Invalidate a detached encoder before a new projection or durable
    /// receipt can replace its original identity.
    func cancelCheckpointEncoding() {
        checkpointEncodingTicket = nil
        checkpointEncodingTask?.cancel()
        checkpointEncodingTask = nil
    }

    /// A checkpoint is optimization/display state, never authority to send.
    /// Exact accepted receipt, session scope and full cursor projection are
    /// checked again against current server history before use.
    func persistRecoveryCheckpoint(force: Bool = false) {
        if force { cancelCheckpointEncoding() }
        guard !runtimeRetired, checkpointEncodingTask == nil,
              let store = draftStore, let receipt = activeTurnRecovery,
              receipt.terminalStatus == nil, pendingSend == nil,
              streamID == receipt.runID, let cursor = lastEventID,
              buffer.canResume(at: cursor), let historyEnd = confirmedHistoryEnd else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastCheckpointWrite >= 2 else { return }
        lastCheckpointWrite = now
        guard !buffer.exceedsCheckpointPayloadBudget(LocalDataFileStore.maxCheckpointBytes) else { return }
        let checkpoint = RunRecoveryCheckpoint(version: 1, scope: displayScope,
            sessionID: sessionID, receipt: receipt, historyEnd: historyEnd,
            olderOffset: olderOffset, cursor: cursor, projection: buffer,
            approvals: pendingApprovals, clarifies: pendingClarifies)
        // A forced background/approval boundary keeps the synchronous
        // atomic write contract. Routine token events encode an immutable
        // value off-main, with at most one outstanding encoder per owner.
        if force {
            guard let encoded = try? JSONEncoder().encode(checkpoint) else { return }
            _ = store.saveCheckpoint(encoded)
            return
        }
        let ticket = UUID()
        let generation = revision
        checkpointEncodingTicket = ticket
        let encoder = Task.detached(priority: .utility) { () -> Data? in
            guard !Task.isCancelled else { return nil }
            return try? JSONEncoder().encode(checkpoint)
        }
        checkpointEncodingTask = encoder
        Task { [weak self] in
            let encoded = await encoder.value
            guard let self, self.checkpointEncodingTicket == ticket else { return }
            self.checkpointEncodingTask = nil
            self.checkpointEncodingTicket = nil
            guard !self.runtimeRetired, !self.suspended,
                  self.revision == generation, self.activeTurnRecovery == receipt,
                  self.pendingSend == nil, self.streamID == receipt.runID,
                  self.lastEventID != nil, !self.buffer.terminal,
                  let encoded else { return }
            // Commit only on the model actor. A newer force-save, reset,
            // receipt retirement or scope retirement cannot be overwritten.
            _ = store.saveCheckpoint(encoded)
        }
    }

    func restoreRecoveryCheckpoint(from snapshot: ChatSnapshot) {
        guard !recoveryCheckpointRead, snapshot.activeRunEvidence != .unknown else { return }
        recoveryCheckpointRead = true
        // A delayed authoritative GET must never replace a newer in-memory
        // stream accumulator with an older disk replay point.
        guard lastEventID == nil, let store = draftStore, let receipt = activeTurnRecovery,
              receipt.terminalStatus == nil, pendingSend == nil,
              let data = store.loadCheckpoint().value,
              let saved = try? JSONDecoder().decode(RunRecoveryCheckpoint.self, from: data),
              let projection = saved.resumeProjection(scope: displayScope, sessionID: sessionID,
                  receipt: receipt, snapshot: snapshot) else { return }
        buffer = projection
        lastEventID = saved.cursor
        olderOffset = saved.olderOffset
        // Only current server control evidence can make a card actionable;
        // saved controls must not reauthorize an already answered request.
        flush()
    }
    var recoveryInstanceID: String?
    @Published var lastFinalizedRecord: RunFinalizedRecord?
    var lastFinalizedOutcome: RunTerminalStatus? { lastFinalizedRecord?.outcome }

    func saveFinalizedOutcome(runID: String, outcome: RunTerminalStatus, history: ChatSnapshot) -> Bool {
        let record = RunFinalizedRecord(scope: displayScope, sessionID: sessionID, runID: runID,
            outcome: outcome, historyEnd: history.rawMessageEndIndex, headID: history.messages.last?.id)
        guard let data = try? JSONEncoder().encode(record) else {
            recordLocalWrite(.failed(.encoding), record: .runOutcome)
            return false
        }
        let result = draftStore?.saveRunOutcome(data) ?? .ok
        guard result.succeeded else {
            recordLocalWrite(result, record: .runOutcome)
            return false
        }
        recordSuccessfulLocalWrite(record: .runOutcome)
        lastFinalizedRecord = record
        return true
    }
    var recoveryOwnerKey: RecoveryScheduler.OwnerKey {
        .init(scope: displayScope.isEmpty ? String(describing: ObjectIdentifier(api)) : displayScope,
              session: sessionID)
    }
    private var recoveryInstance: String {
        recoveryInstanceID ?? (displayScope.isEmpty ? String(describing: ObjectIdentifier(api)) : displayScope)
    }

    func recoveryHistory(sessionID: String, before: Int?) async throws -> ChatSnapshot {
        try await RecoveryScheduler.shared.perform(instance: recoveryInstance, session: sessionID) {
            try await api.history(sessionID: sessionID, before: before)
        }
    }

    func recoveryProbe(sessionID: String, runID: String) async throws -> ActiveRunProbe {
        try await RecoveryScheduler.shared.perform(instance: recoveryInstance, session: sessionID) {
            try await api.probeActiveRun(sessionID: sessionID, runID: runID)
        }
    }
    var runtimeLogToken: RuntimeLogToken?
    #if canImport(UIKit)
    private var runtimeObservation: AnyCancellable?
    private var runtimeObservationScheduled = false

    func observeRuntime(_ action: @escaping @MainActor () -> Void) {
        runtimeObservation = objectWillChange.sink { [weak self] in
            guard let self, !self.runtimeRetired, !self.runtimeObservationScheduled else { return }
            self.runtimeObservationScheduled = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.runtimeObservationScheduled = false
                guard !self.runtimeRetired else { return }
                action()
            }
        }
    }
    #endif

    var hasUnsettledRuntime: Bool {
        streamTask != nil || running || submitting || reconciling || syncing || loading ||
            uncertain || pendingSend != nil || activeTurnRecovery != nil ||
            sendingWhileRunning || approving || clarifying
    }

    func retireRuntime() {
        guard !runtimeRetired else { return }
        runtimeRetired = true
        cancelCheckpointEncoding()
        #if canImport(UIKit)
        runtimeObservation?.cancel()
        runtimeObservation = nil
        #endif
        onAuthenticationRequired = nil
        onApprovalArrived = nil; onApprovalResolved = nil
        onClarifyArrived = nil; onClarifyResolved = nil
        disconnect()
    }

    func recordRuntimeLog(_ level: RuntimeLogRecorder.Level, _ tag: String, _ message: String) {
        guard !runtimeRetired else { return }
        let recorder = RuntimeLogRecorder.shared
        if let current = recorder.currentToken(),
           current.scope.sessionID == sessionID,
           current.scope.instanceID + "|" + current.scope.accountScope == displayScope {
            runtimeLogToken = current
        }
        guard let token = runtimeLogToken else { return }
        recorder.record(level, tag, message, token: token)
    }
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
    /// Runtime-only proof for the current explicit send's visual anchor.
    var latestSubmissionFocus: ChatTurnFocusProof?
    /// Latest authoritative tail, retained only for bounded read-only recovery.
    /// Older verification pages are never inserted into the visible transcript.
    var latestRecoverySnapshot: ChatSnapshot?
    /// Known missing status record; the user may retry an explicit GET or
    /// open another chat, but this is never permission to replay a POST.
    @Published var unavailableRunStatusID: String?
    @Published var activeRecoveryUnreadable = false
    var authenticationReported = false
    var streamTask: Task<Void,Never>?
    /// One bounded receipt probe per receipt/page. The task is cancelled by
    /// disconnect or a newer load, and only `.alive` can attach the run.
    var activeRunProbeTask: Task<Void,Never>?
    var activeRunProbeRunID: String?
    var activeRunProbeTicket: UUID?
    /// A single bounded, read-only recovery owner for uncertain sends/runs.
    /// It never submits a chat POST or resumes a user-paused queue.
    var automaticReconciliationTask: Task<Void, Never>?
    var automaticReconciliationTicket: UUID?
    var automaticReconciliationWaiting = false
    @Published var automaticRecoveryQuiet = false
    var automaticReconciliationSteadyNanoseconds: UInt64 = 60_000_000_000
    var automaticReconciliationSlowNanoseconds: UInt64 = 120_000_000_000
    var automaticReconciliationSlowAfterNanoseconds: UInt64 = 1_800_000_000_000
    // Transport evidence only, not delivery or terminal evidence.
    var reapedTransportRunID: String?
    var hidesRoutineRecoveryNotice: Bool {
        automaticRecoveryQuiet && unavailableRunStatusID == nil && !pendingAbsent && !authenticationRequired &&
            !recoveryRecordsUnreadable &&
            localPersistenceIssue == nil && !queuePersistenceFailed && !runRecoveryNoticeShown &&
            (error == nil || historyLoadFailurePending)
    }
    var automaticReconciliationDelaysNanoseconds: [UInt64] = [
        2_000_000_000, 5_000_000_000, 10_000_000_000,
        20_000_000_000, 40_000_000_000, 60_000_000_000
    ]
    /// 历史 GET 因**网络类**原因失败，还欠一次成功的权威读取。
    ///
    /// 与 `uncertain` 严格分开：那个表示「POST 结果待核对」，这个只表示
    /// 「屏幕上的内容可能不是最新」。把两者混用会让一次超时锁死发送。
    var historyLoadFailurePending = false
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
        queueAutomaticDispatchPaused = queueUserPaused || queueRecoveryPaused ||
            localRecordIssues[.queuePause] != nil
    }

    func pauseQueueForRecovery() {
        queueRecoveryPaused = true
        updateQueuePause()
    }

    func resumeQueueAfterRecovery() {
        guard !recoveryOnly else { return }
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
    @Published private(set) var localRecordIssues: [LocalDataRecord: LocalDataIssue] = [:]
    /// Aggregate by category for the compact presentation only. The exact
    /// record map is authoritative and never cleared by a different write.
    var localPersistenceIssues: [LocalDataKind: LocalDataIssue] {
        var result: [LocalDataKind: LocalDataIssue] = [:]
        for record in LocalDataRecord.allCases {
            if let issue = localRecordIssues[record], result[record.kind] == nil {
                result[record.kind] = issue
            }
        }
        return result
    }
    var localPersistenceIssue: LocalDataIssue? {
        LocalDataRecord.allCases.compactMap { localRecordIssues[$0] }.first
    }
    /// A file-write failure also feeds the legacy queue flag for the queue UI.
    /// Keep that derived mirror in sync so every entry point shows the same
    /// sticky state, including the composer and queue manager.
    var queuePersistenceFailed: Bool {
        queueRecoveryUnreadable || queueSaveFailed || localPersistenceIssues[.queue] != nil
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
        // Optional for backward compatibility. Text and attachment equality
        // never grants ownership of another queued transaction.
        var queuedTurnID: String? = nil

        func resolution(in snapshot: ChatSnapshot) -> PendingReconcileResult {
            DeliveryReconciliationPolicy.resolve(
                text: text, attachments: attachments, historyEnd: historyEnd,
                knownIDs: knownIDs, snapshot: snapshot)
        }
    }
    @Published var pendingRecoveryUnreadable = false
    @Published private(set) var queueRecoveryUnreadable = false
    private var restoringRecoveryRecords = false

    var recoveryRecordsUnreadable: Bool {
        pendingRecoveryUnreadable || activeRecoveryUnreadable || queueRecoveryUnreadable
    }

    /// Retry only the records that could not be read. Never overwrite a live
    /// in-memory receipt or treat undecodable bytes as an empty queue.
    @discardableResult
    func restoreUnreadableRecoveryRecords() -> Bool {
        guard recoveryRecordsUnreadable else { return true }
        guard !runtimeRetired, !submitting, !loading, !syncing, !running,
              !reconciling, let store = draftStore else { return false }
        restoringRecoveryRecords = true
        defer { restoringRecoveryRecords = false }
        if pendingRecoveryUnreadable, pendingSend == nil {
            let result = store.loadPending()
            if result.result.succeeded {
                if let data = result.value {
                    if let record = try? JSONDecoder().decode(PendingSend.self, from: data) {
                        pendingRecoveryUnreadable = false
                        pendingSend = record
                    }
                } else { pendingRecoveryUnreadable = false }
            }
        }
        if activeRecoveryUnreadable, activeTurnRecovery == nil {
            let result = store.loadActiveRun()
            if result.result.succeeded {
                if let data = result.value {
                    if let record = try? JSONDecoder().decode(ActiveTurnRecovery.self, from: data) {
                        activeRecoveryUnreadable = false
                        activeTurnRecovery = record
                        activeTurnHistoryBoundary = record.historyEnd
                    }
                } else { activeRecoveryUnreadable = false }
            }
        }
        if queueRecoveryUnreadable, queuedTurns.isEmpty {
            let result = store.loadQueuedResult()
            if result.result.succeeded {
                if let data = result.value {
                    if let restored = ChatSendQueueCodec.decode(data) {
                        restoreQueueSnapshot(restored)
                        queueRecoveryUnreadable = false
                    }
                } else { queueRecoveryUnreadable = false }
            }
        }
        // An accessible file is not proof of remote absence or completion.
        uncertain = true
        pauseQueueForRecovery()
        if !recoveryRecordsUnreadable {
            notice = "已恢复本地记录，正在等待联网同步，不会自动重发。"
        }
        return !recoveryRecordsUnreadable
    }

    private func restoreQueueSnapshot(_ turns: [ChatQueuedTurn]) {
        queuedTurns = ChatQueueOrdering.prioritize(turns.map { original in
            var turn = original
            if turn.delivery == .submitting {
                turn.delivery = .uncertain
                turn.automaticAfterStreamID = nil
            }
            return turn
        })
        if !queuedTurns.isEmpty { pauseQueueForRecovery() }
    }

    func abandonUnreadablePending() {
        guard !submitting, !syncing, !loading else { return }
        let result = draftStore?.savePending(nil) ?? .ok
        guard result.succeeded else { recordLocalWrite(result, record: .pendingSend); return }
        pendingRecoveryUnreadable = false
        recordSuccessfulLocalWrite(record: .pendingSend)
        uncertain = true // A subsequent GET is still required.
        notice = "已放弃损坏的本地记录，请同步消息后再发送。"
    }

    var pendingSend: PendingSend? {
        didSet {
            // Persist before POST and clear only when resolved or explicitly abandoned.
            if !restoringRecoveryRecords {
                _ = persistPendingSend()
            }
        }
    }

    @discardableResult
    func persistPendingSend() -> LocalStoreWriteResult {
        guard !runtimeRetired else { return .failed(.diskWrite) }
        guard !pendingRecoveryUnreadable else { return .failed(.corruptFile) }
        guard let draftStore else { return .ok }
        let result: LocalStoreWriteResult
        if let pendingSend {
            if let data = try? JSONEncoder().encode(pendingSend) {
                result = draftStore.savePending(data)
            } else { result = .failed(.encoding) }
        } else { result = draftStore.savePending(nil) }
        if result.succeeded { recordSuccessfulLocalWrite(record: .pendingSend) }
        else { recordLocalWrite(result, record: .pendingSend) }
        return result
    }

    /// Retire pending evidence only after durable removal succeeds. No
    /// in-memory success is published if a protected file is inaccessible.
    @discardableResult
    func clearPendingSend(expectedID: String) -> Bool {
        guard !runtimeRetired, !pendingRecoveryUnreadable,
              pendingSend?.id == expectedID else { return false }
        let result = draftStore?.savePending(nil) ?? .ok
        guard result.succeeded else {
            recordLocalWrite(result, record: .pendingSend)
            uncertain = true
            pauseQueueForRecovery()
            return false
        }
        recordSuccessfulLocalWrite(record: .pendingSend)
        restoringRecoveryRecords = true
        pendingSend = nil
        restoringRecoveryRecords = false
        pendingAbsent = false
        return true
    }

    /// A persisted accepted receipt owns only its own queue and pending
    /// transaction. Retirement order preserves evidence across interruption.
    @discardableResult
    func settleAcceptedReceipt(_ receipt: ActiveTurnRecovery) -> Bool {
        guard !runtimeRetired, activeTurnRecovery == receipt else { return false }
        if let id = receipt.queuedTurnID,
           !retireAcceptedQueueTurn(id: id, nextRunID: receipt.runID) { return false }
        if let pending = pendingSend, pending.id == receipt.pendingSendID {
            guard clearPendingSend(expectedID: pending.id) else { return false }
        }
        return true
    }

    /// Write the accepted-run receipt BEFORE deleting the pre-POST PendingSend.
    /// On failure keep PendingSend durable and suppress automatic queue dispatch.
    @discardableResult
    func rememberAcceptedTurn(runID: String, text: String,
                              attachments: [ChatAttachmentPayload],
                              knownIDs: Set<String>) -> Bool {
        guard !runtimeRetired else { return false }
        var receipt = ActiveTurnRecovery(
            runID: runID, historyEnd: activeTurnHistoryBoundary,
            knownIDs: knownIDs, text: text,
            attachmentPaths: Set(attachments.map(\.path)),
            pendingSendID: pendingSend?.id, queuedTurnID: pendingSend?.queuedTurnID)
        if let command = pendingSlashCommand, attachments.isEmpty {
            switch command.kind {
            case .compress, .reset: receipt.commandAllowsEmptyReply = true
            case .other: break
            }
        }
        guard let data = try? JSONEncoder().encode(receipt) else {
            recordLocalWrite(.failed(.encoding), record: .activeRun)
            return false
        }
        let result = draftStore?.saveActiveRun(data) ?? .ok
        guard result.succeeded else {
            recordLocalWrite(result, record: .activeRun)
            return false
        }
        recordSuccessfulLocalWrite(record: .activeRun)
        activeTurnRecovery = receipt
        return true
    }

    /// Only an exact, already accepted Run can gain terminal evidence.
    /// A conflicting status or failed durable write must not unlock sending.
    @discardableResult
    func rememberTerminalStatus(runID: String, outcome: RunTerminalStatus,
                                explicitlyEmptyReply: Bool = false) -> Bool {
        guard !runtimeRetired else { return false }
        guard var receipt = activeTurnRecovery else { return true }
        guard receipt.runID == runID else { return false }
        if let previous = receipt.terminalStatus {
            guard previous == outcome else { return false }
            if !explicitlyEmptyReply || receipt.terminalAllowsEmptyReply == true { return true }
        }
        receipt.terminalStatus = outcome
        if outcome == .completed && explicitlyEmptyReply { receipt.terminalAllowsEmptyReply = true }
        guard let data = try? JSONEncoder().encode(receipt) else {
            recordLocalWrite(.failed(.encoding), record: .activeRun)
            return false
        }
        let result = draftStore?.saveActiveRun(data) ?? .ok
        guard result.succeeded else {
            recordLocalWrite(result, record: .activeRun)
            return false
        }
        recordSuccessfulLocalWrite(record: .activeRun)
        activeTurnRecovery = receipt
        return true
    }

    /// A clear is authoritative only after its protected-file removal succeeds.
    /// Failed removal must not silently erase recovery evidence from memory.
    @discardableResult
    func clearAcceptedTurnRecovery() -> Bool {
        guard !runtimeRetired else { return false }
        guard let receipt = activeTurnRecovery else { return true }
        guard settleAcceptedReceipt(receipt) else {
            uncertain = true
            pauseQueueForRecovery()
            return false
        }
        cancelCheckpointEncoding()
        activeRunProbeTask?.cancel()
        activeRunProbeTask = nil
        activeRunProbeRunID = nil
        activeRunProbeTicket = nil
        let result = draftStore?.saveActiveRun(nil) ?? .ok
        guard result.succeeded else {
            recordLocalWrite(result, record: .activeRun)
            uncertain = true
            return false
        }
        recordSuccessfulLocalWrite(record: .activeRun)
        activeTurnRecovery = nil
        _ = draftStore?.saveCheckpoint(nil)
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
        notice = "已放弃本地任务记录，没有重发消息。请同步后再继续。"
    }

    func abandonUnreadableActiveRecovery() {
        guard !submitting, !loading, !syncing, !running, !reconciling else { return }
        let result = draftStore?.saveActiveRun(nil) ?? .ok
        guard result.succeeded else { recordLocalWrite(result, record: .activeRun); return }
        activeRecoveryUnreadable = false
        recordSuccessfulLocalWrite(record: .activeRun)
        pauseQueueForRecovery()
        uncertain = true
        notice = "已放弃损坏的任务记录，请同步消息；不会自动重发或继续队列。"
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
    var canSend: Bool { !recoveryOnly && phase.allowsNewTurn(facts) }
    /// 本轮正在跑时，是否还能把这条发出去（steer / queue / interrupt 三条路径之一）。
    /// `running` 不再直接锁死输入栏：Hermes 支持运行中引导，客户端不该比服务端更保守。
    /// 但 `.reconnecting` 一律不放行——重连期间服务端没有活跃 agent 可注入。
    var canSendWhileRunning: Bool { !recoveryOnly && phase.allowsSteer(facts) }

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

    /// Product presentation is distinct from safety facts. Long routine GET
    /// recovery remains compact; a pending original POST or damaged record
    /// always stays visible when user action may be needed.
    var presentationState: SessionPresentationState {
        let persistence = localPersistenceIssue != nil || queuePersistenceFailed
        let requiresAction = authenticationRequired || pendingAbsent || unavailableRunStatusID != nil ||
            !pendingApprovals.isEmpty || !pendingClarifies.isEmpty ||
            recoveryRecordsUnreadable ||
            persistence || runRecoveryNoticeShown ||
            (hasPendingSend && !submitting && activeTurnRecovery == nil)
        let currentActivity = activity
        let verification = uncertain || (hasPendingSend && !submitting) ||
            currentActivity == .needsVerification || recoveryRecordsUnreadable ||
            runRecoveryNoticeShown
        let recovery = hidesRoutineRecoveryNotice ||
            (automaticReconciliationTask != nil &&
             (historyLoadFailurePending || activeTurnRecovery != nil || reapedTransportRunID != nil))
        return SessionPresentationState(activity: currentActivity,
            transcriptAvailable: !transcript.messages.isEmpty,
            routineRecovery: recovery, requiresAction: requiresAction,
            verificationPending: verification, errorPresent: error != nil,
            warningPresent: error != nil || verification || persistence,
            notice: notice)
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
        if uncertain || recoveryRecordsUnreadable ||
            pendingSend != nil || (activeTurnRecovery != nil && !phase.isRunning) {
            return .needsVerification
        }
        if readOnly { return .readOnly }
        if case .streaming(let connected) = phase {
            // A live turn outranks a leftover error string: the stream may still
            // recover, and "操作未完成" would contradict the running spinner.
            if !connected { return .connecting }
            if let runID = streamID {
                if pendingApprovals.contains(where: { $0.runID == runID }) { return .waitingForApproval }
                if pendingClarifies.contains(where: { $0.runID == runID }) { return .waitingForClarify }
            }
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
            draftRecoveryUnreadable = true
            localRecordIssues[.draft] = LocalDataIssue(kind: .draft, failure: issue, observedAt: Date())
            recordRuntimeLog(.warning, "local-store",
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
                notice = "上次消息尚未确认送达，不会自动重发。"
            } else {
                uncertain = true
                pendingRecoveryUnreadable = true
                localRecordIssues[.pendingSend] = LocalDataIssue(kind: .queue, failure: .corruptFile, observedAt: Date())
            }
        } else if let failure = restored?.result.failure {
            pendingRecoveryUnreadable = true
            uncertain = true
            localRecordIssues[.pendingSend] = LocalDataIssue(kind: .queue, failure: failure, observedAt: Date())
        }
        let restoredActive = draftStore?.loadActiveRun()
        if let data = restoredActive?.value {
            if let receipt = try? JSONDecoder().decode(ActiveTurnRecovery.self, from: data) {
                activeTurnRecovery = receipt
                activeTurnHistoryBoundary = receipt.historyEnd
                if pendingSend == nil {
                    uncertain = true
                    notice = "正在同步上次回复，不会重复发送消息。"
                }
            } else {
                activeRecoveryUnreadable = true
                uncertain = true
                localRecordIssues[.activeRun] = LocalDataIssue(
                    kind: .runRecovery, failure: .corruptFile, observedAt: Date())
            }
        } else if let failure = restoredActive?.result.failure {
            activeRecoveryUnreadable = true
            uncertain = true
            localRecordIssues[.activeRun] = LocalDataIssue(
                kind: .runRecovery, failure: failure, observedAt: Date())
        }
        if pendingSend == nil, activeTurnRecovery == nil,
           let data = draftStore?.loadRunOutcome().value,
           let record = try? JSONDecoder().decode(RunFinalizedRecord.self, from: data),
           record.scope == displayScope, record.sessionID == sessionID {
            lastFinalizedRecord = record
        }
        queueUserPaused = draftStore?.loadQueueUserPaused() ?? false
        updateQueuePause()
        let loadedQueue = draftStore?.loadQueuedResult()
        if let data = loadedQueue?.value, let restored = ChatSendQueueCodec.decode(data) {
            restoreQueueSnapshot(restored)
        } else if loadedQueue?.value != nil || loadedQueue?.result.failure != nil {
            queueRecoveryUnreadable = true
            uncertain = true
            pauseQueueForRecovery()
            recordLocalWrite(.failed(loadedQueue?.result.failure ?? .corruptFile), kind: .queue)
        }
    }

    /// Record only the failure category and time. Message text, identifiers,
    /// endpoints and paths never enter this state or its diagnostics.
    func recordLocalWrite(_ result: LocalStoreWriteResult?,
                          kind: LocalDataKind, observedAt: Date = Date()) {
        recordLocalWrite(result, record: .primary(for: kind), observedAt: observedAt)
    }

    func recordLocalWrite(_ result: LocalStoreWriteResult?, record: LocalDataRecord,
                          observedAt: Date = Date()) {
        guard let failure = result?.failure else { return }
        localRecordIssues[record] = LocalDataIssue(kind: record.kind, failure: failure, observedAt: observedAt)
        if record == .queuedTurns { queueSaveFailed = true }
        if record == .queuePause { updateQueuePause() }
        recordRuntimeLog(.warning, "local-store",
            "persistence degraded record=\(record.rawValue) reason=\(failure.rawValue)")
    }

    /// A successful explicit retry for the same data kind clears only that
    /// kind's sticky issue. Ordinary typing does not call this: an earlier
    /// failed write remains visible until the recovery center proves recovery.
    func recordVerifiedLocalRetry(_ result: LocalStoreWriteResult, kind: LocalDataKind) {
        if result.succeeded {
            recordSuccessfulLocalWrite(kind: kind)
        } else {
            recordLocalWrite(result, kind: kind)
        }
    }

    /// A successful ordinary write for this kind clears a previous issue of
    /// that kind. Other kinds remain independent. The composer calls this only
    /// after a verified write; a model-side no-op save is not evidence of a
    /// durable write.
    func recordSuccessfulLocalWrite(kind: LocalDataKind) {
        recordSuccessfulLocalWrite(record: .primary(for: kind))
    }

    func recordSuccessfulLocalWrite(record: LocalDataRecord) {
        if record == .draft && draftRecoveryUnreadable { return }
        if record == .queuedTurns && queueRecoveryUnreadable { return }
        if record == .pendingSend && pendingRecoveryUnreadable { return }
        if record == .activeRun && activeRecoveryUnreadable { return }
        if localRecordIssues[record] != nil { localRecordIssues.removeValue(forKey: record) }
        if record == .queuedTurns { queueSaveFailed = false }
        if record == .queuePause { updateQueuePause() }
    }

    /// A failed cold read is not an empty draft. No automatic write is
    /// allowed until the original record can be read or the user discards it.
    func restoreUnreadableDraft() -> LocalStoreWriteResult {
        guard draftRecoveryUnreadable, !runtimeRetired, let draftStore else { return .failed(.corruptFile) }
        let loaded = draftStore.loadDraftResult()
        guard loaded.result.succeeded else {
            recordLocalWrite(loaded.result, record: .draft)
            return loaded.result
        }
        // Keep the write guard set while publishing the recovered value.
        draft = loaded.value
        draftRecoveryUnreadable = false
        recordSuccessfulLocalWrite(record: .draft)
        return .ok
    }

    func abandonUnreadableDraft() -> LocalStoreWriteResult {
        guard draftRecoveryUnreadable, !runtimeRetired, let draftStore else { return .failed(.corruptFile) }
        let result = draftStore.save("")
        guard result.succeeded else {
            recordLocalWrite(result, record: .draft)
            return result
        }
        draft = ""
        draftRecoveryUnreadable = false
        recordSuccessfulLocalWrite(record: .draft)
        return .ok
    }

    /// Retry a pending legacy migration without changing the current in-memory
    /// draft or queue. A successful verified migration clears its category.
    @discardableResult
    func retryLocalMigration() -> LocalStoreWriteResult {
        guard !recoveryRecordsUnreadable else { return .failed(.corruptFile) }
        guard let draftStore else { return .ok }
        let results = draftStore.retryMigration()
        // Migration/read success does not prove the current in-memory value
        // was saved. Only a successful explicit write can clear a write issue.
        if !results.draft.succeeded { recordLocalWrite(results.draft, kind: .draft) }
        if !results.queue.succeeded { recordLocalWrite(results.queue, kind: .queue) }
        return results.draft.succeeded ? results.queue : results.draft
    }

    @discardableResult
    func validateLocalData() -> LocalStoreWriteResult {
        guard restoreUnreadableRecoveryRecords() else {
            return .failed(.corruptFile)
        }
        guard let draftStore else { return .ok }
        let migration = draftStore.retryMigration()
        let checks: [(LocalDataRecord, LocalStoreWriteResult)] = [
            (.draft, migration.draft), (.queuedTurns, migration.queue),
            (.pendingSend, draftStore.loadPending().result),
            (.activeRun, draftStore.loadActiveRun().result),
            (.attachmentDraft, draftStore.loadAttachmentDraft().result),
            (.runOutcome, draftStore.loadRunOutcome().result)
        ]
        for (record, result) in checks where !result.succeeded {
            recordLocalWrite(result, record: record)
        }
        let result = checks.first(where: { !$0.1.succeeded })?.1 ?? .ok
        // Reading old bytes (or a missing file) cannot acknowledge a failed
        // newer write. Preserve the warning until the corresponding write
        // succeeds; keep independent queue failures visible as well.
        return result
    }
}


@MainActor
final class ConversationRuntimeRegistry {
    struct Key: Hashable {
        let instanceID: String
        let accountScope: String
        let sessionID: String
    }
    private struct Entry {
        let model: NativeChatModel
        var presentation: UUID?
        var lastPresentation: UUID
        var access: UInt64
    }
    private var access: UInt64 = 0
    private var entries: [Key: Entry] = [:]

    func claim(_ key: Key, presentation: UUID, make: () -> NativeChatModel) -> NativeChatModel {
        access &+= 1
        if var entry = entries[key] {
            if entry.model.recoveryOnly {
                entry.model.recoveryOnly = false
                // Opening a recovery-only runtime is not permission to
                // automatically resume a queue restored from disk.
                entry.model.pauseQueueForRecovery()
            }
            entry.presentation = presentation
            entry.lastPresentation = presentation
            entry.access = access
            entries[key] = entry
            return entry.model
        }
        let model = make()
        entries[key] = Entry(model: model, presentation: presentation,
            lastPresentation: presentation, access: access)
        return model
    }

    func restoreForRecovery(_ key: Key, make: () -> NativeChatModel) -> NativeChatModel? {
        guard entries[key] == nil else { return nil }
        access &+= 1
        let model = make()
        model.recoveryOnly = true
        model.pauseQueueForRecovery()
        entries[key] = Entry(model: model, presentation: nil,
            lastPresentation: UUID(), access: access)
        return model
    }

    func owns(_ key: Key, presentation: UUID) -> Bool {
        entries[key]?.presentation == presentation
    }

    func contains(_ key: Key) -> Bool { entries[key] != nil }
    func contains(_ key: Key, model: NativeChatModel) -> Bool { entries[key]?.model === model }
    func mayWriteDraft(_ key: Key, presentation: UUID) -> Bool {
        entries[key]?.lastPresentation == presentation
    }

    /// A sheet/scene may temporarily unmount the same view. Restore only its
    /// existing lease, never take ownership away from a newer presentation.
    func reattach(_ key: Key, presentation: UUID, model: NativeChatModel) -> Bool {
        guard var entry = entries[key], entry.model === model,
              entry.lastPresentation == presentation else { return false }
        entry.presentation = presentation
        entries[key] = entry
        return true
    }

    var all: [(Key, NativeChatModel)] {
        entries.map { ($0.key, $0.value.model) }
    }

    func detach(_ key: Key, presentation: UUID) {
        guard var entry = entries[key], entry.presentation == presentation else { return }
        entry.presentation = nil
        entries[key] = entry
    }

    var detached: [(Key, NativeChatModel)] {
        entries.compactMap { key, entry in
            entry.presentation == nil ? (key, entry.model) : nil
        }
    }

    /// Keep the current route even if its presentation is temporarily hidden.
    /// Bound offscreen streaming memory; never evict an in-flight original POST
    /// or a runtime whose persistence is degraded. Remaining work has a durable
    /// receipt and is handed back to the app's read-only recovery coordinator.
    func pruneDetached(excluding current: Key?, limit: Int = 4,
                       onHandoff: (Key, NativeChatModel) -> Void = { _, _ in }) {
        let eligible = entries.filter { key, entry in
            key != current && entry.presentation == nil
        }
        for (key, entry) in eligible where !entry.model.hasUnsettledRuntime {
            retire(key)
        }
        let remaining = entries.filter { key, entry in
            key != current && entry.presentation == nil
        }
        let excess = max(0, remaining.count - limit)
        let evictable = remaining.filter { _, entry in
            let model = entry.model
            return !model.submitting && !model.sendingWhileRunning && !model.approving &&
                !model.clarifying && !model.stopping && model.localPersistenceIssue == nil &&
                !model.queuePersistenceFailed && !model.runRecoveryNoticeShown &&
                (model.activeTurnRecovery != nil || model.pendingSend != nil)
        }.sorted { $0.value.access < $1.value.access }
        for (key, entry) in evictable.prefix(excess) {
            onHandoff(key, entry.model)
            retire(key)
        }
    }

    func suspendAll() {
        for entry in entries.values { entry.model.disconnect() }
    }

    func retire(_ key: Key) {
        entries.removeValue(forKey: key)?.model.retireRuntime()
    }

    func retireScope(instanceID: String, accountScope: String? = nil) {
        let keys = entries.keys.filter { key in
            key.instanceID == instanceID &&
                (accountScope == nil || key.accountScope == accountScope)
        }
        for key in keys { retire(key) }
    }

    func detachScope(instanceID: String, accountScope: String) {
        for key in Array(entries.keys) where key.instanceID == instanceID && key.accountScope == accountScope {
            guard var entry = entries[key] else { continue }
            entry.presentation = nil
            entries[key] = entry
        }
    }

    func retireAll() {
        let old = Array(entries.values)
        entries.removeAll()
        for entry in old { entry.model.retireRuntime() }
    }
}


/// Protected, bounded snapshot. Cursor, exact deduplication set and all
/// accumulator state are encoded in one atomic envelope, not separate files.
struct RunRecoveryCheckpoint: Codable, Sendable {
    let version: Int
    let scope: String
    let sessionID: String
    let receipt: ActiveTurnRecovery
    let historyEnd: Int
    let olderOffset: Int
    let cursor: String
    let projection: ChatTranscript
    let approvals: [ChatPendingApproval]
    let clarifies: [ChatPendingClarify]

    func resumeProjection(scope: String, sessionID: String,
                          receipt: ActiveTurnRecovery, snapshot: ChatSnapshot) -> ChatTranscript? {
        guard version == 1, self.scope == scope, self.sessionID == sessionID,
              self.receipt == receipt, receipt.terminalStatus == nil,
              snapshot.sessionID == sessionID, !snapshot.readOnly,
              snapshot.activeRunEvidence == .active(receipt.runID),
              projection.canResume(at: cursor), historyEnd >= 0, historyEnd < Int.max, olderOffset >= 0,
              snapshot.rawMessageEndIndex >= historyEnd,
              snapshot.rawMessageEndIndex <= historyEnd + 1 else { return nil }
        var result = projection
        // A newer canonical assistant or tool window is incompatible with this
        // projection; rebuild from server history instead of risking duplicates.
        for row in snapshot.messages {
            if let existing = result.messages.first(where: { $0.id == row.id }) {
                guard existing.role == row.role, existing.content == row.content,
                      existing.sourceIndex == row.sourceIndex,
                      existing.attachmentPaths == row.attachmentPaths else { return nil }
            } else {
                // The original accepted local bubble may acquire its canonical
                // server ID after the last checkpoint. Only that exact row is
                // allowed; another user/assistant means the base changed.
                guard row.sourceIndex == historyEnd, row.role == "user",
                      row.content == receipt.text, Set(row.attachmentPaths) == receipt.attachmentPaths,
                      let index = result.messages.lastIndex(where: {
                        $0.role == "user" && $0.sourceIndex == nil && $0.delivery == .accepted &&
                        $0.content == receipt.text && Set($0.attachmentPaths) == receipt.attachmentPaths
                      }) else { return nil }
                let previousID = result.messages[index].id
                result.messages[index] = row
                for toolIndex in result.tools.indices where result.tools[toolIndex].afterMessageID == previousID {
                    result.tools[toolIndex].afterMessageID = row.id
                }
            }
        }
        for tool in snapshot.tools {
            guard result.tools.contains(where: {
                $0.id == tool.id && $0.done == tool.done && $0.isError == tool.isError &&
                $0.result == tool.result && $0.args == tool.args
            }) else { return nil }
        }
        return result
    }
}


/// Displayable result survives receipt retirement. It is never a source of
/// sending authority; current server history and active receipts decide that.
struct RunFinalizedRecord: Codable, Equatable {
    let scope: String
    let sessionID: String
    let runID: String
    let outcome: RunTerminalStatus
    let historyEnd: Int
    let headID: String?
}
