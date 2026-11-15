import Foundation

/// 与相位**正交**的独立事实。
///
/// 它们能与任意相位同时成立，所以不进 `ChatPhase` 枚举——塞进去会丢信息。
/// 三处真实的并存关系决定了这一点：
/// - `suspended`：离开会话页时连接暂停，但服务端那一轮仍在跑。
/// - `reconciling`：核对用的那次 GET 自己会走 `.syncing`，两个都得为真。
/// - `sendingWhileRunning`：steer 请求在途，本轮同时仍在跑。
struct ChatFacts: Equatable {
    /// 后端声明这段历史只读（联网核对完成前也一律只读）。
    var readOnly: Bool = true
    /// POST 结果待核对。
    var uncertain: Bool = false
    /// 已离开会话页，连接暂停。**不代表本轮结束**。
    var suspended: Bool = false
    /// 有一次 GET 归核对流程所有（`reconcilePending`）。
    var reconciling: Bool = false
    /// 有一笔发送快照等用户决定（核对/重发/放弃）。
    var hasPendingSend: Bool = false
    /// 核对已确认后台不存在这条，可以重发。
    var pendingAbsent: Bool = false
    /// 正在把一条消息注入运行中的本轮（steer 请求在途）。
    var sendingWhileRunning: Bool = false
}

/// 会话当前在做的那一件事。**互斥**：任意时刻有且只有一个。
///
/// 取代原先 17 个可独立翻转的布尔标志中「描述当前活动」的那一批。那些标志允许
/// 出现「reconnecting 与 running 同时为真」这类无法用类型表达的组合，于是四个
/// 谓词（`canSend` / `canSendWhileRunning` / `canResendPending` / `activity`）
/// 各自把同一批布尔重新组合一遍，组合集合互不一致——`canSendWhileRunning` 漏了
/// `!reconnecting` 就是这种漂移的直接产物：重连期间服务端没有活跃 agent 可注入，
/// 放行只会让用户以为引导送达了。
///
/// 收成单值相位后，组合方式只剩一处 `switch`，编译器强制穷尽：漏一个 case 就编译
/// 失败。这是唯一能防住「四个谓词各自漂移」的机制。
///
/// 注意 `.loading` 与 `.syncing` 是**同一件事的两个强度**（原实现里 loading 时
/// syncing 也必然为真），所以 `.loading` 的 `isSyncing` 也返回 true。
enum ChatPhase: Equatable {
    /// 无请求、无流、无本地缓存。唯一「可以发起新一轮」的静止态。
    case idle
    /// 显示磁盘历史，等待（或正在）联网核对。
    case cached(savedAt: Date, syncing: Bool)
    /// 首次加载或前台恢复，界面显示整页占位。
    case loading
    /// 静默同步历史，已有内容保持可见。
    case syncing
    /// 流已断开，正在用 GET 恢复后台状态。**本轮并未结束**。
    case reconnecting
    /// POST 已发出，还没拿到 stream id。
    case submitting
    /// 本轮在跑。`connected == false` 表示还没收到第一帧。
    case streaming(connected: Bool)
    /// 已请求停止，等服务端确认。
    case stopping
    /// 登录态失效。
    case needsLogin
}

// MARK: - 派生事实

extension ChatPhase {
    /// 「本轮未结束」：提交中、流式、重连、停止中都属于同一轮。
    /// **重连也算**——这正是 `canSendWhileRunning` 原先漏判的地方。
    var isRunning: Bool {
        switch self {
        case .submitting, .streaming, .reconnecting, .stopping: return true
        case .idle, .cached, .loading, .syncing, .needsLogin: return false
        }
    }

    /// 流是否已收到帧。只有 `.streaming` 携带这个信息。
    var isConnected: Bool {
        if case .streaming(let connected) = self { return connected }
        return false
    }

    var isLoading: Bool {
        switch self {
        case .loading: return true
        case .idle, .cached, .syncing, .reconnecting, .submitting, .streaming,
             .stopping, .needsLogin: return false
        }
    }

    /// 静默同步中。`.cached` 携带自己的 syncing 位；`.loading` 也同步中
    /// （原实现里 loading 与 syncing 同时置起，这里保持同一语义）。
    var isSyncing: Bool {
        switch self {
        case .syncing, .loading: return true
        case .cached(_, let syncing): return syncing
        case .idle, .reconnecting, .submitting, .streaming, .stopping, .needsLogin: return false
        }
    }

    var isCached: Bool {
        switch self {
        case .cached: return true
        case .idle, .loading, .syncing, .reconnecting, .submitting, .streaming,
             .stopping, .needsLogin: return false
        }
    }

    var cachedSince: Date? {
        if case .cached(let savedAt, _) = self { return savedAt }
        return nil
    }
}

// MARK: - 谓词（全部集中在这里，`switch` 穷尽）

extension ChatPhase {
    /// 能否发起新的一轮。
    func allowsNewTurn(_ facts: ChatFacts) -> Bool {
        guard !facts.readOnly, !facts.uncertain, !facts.suspended,
              !facts.reconciling, !facts.hasPendingSend,
              !facts.sendingWhileRunning else { return false }
        switch self {
        case .idle: return true
        case .cached, .loading, .syncing, .reconnecting, .submitting, .streaming,
             .stopping, .needsLogin: return false
        }
    }

    /// 本轮正在跑时，是否还能把这条发出去（steer / queue / interrupt）。
    /// `.reconnecting` 明确为 false —— 这是本版修的真缺陷。
    func allowsSteer(_ facts: ChatFacts) -> Bool {
        guard !facts.readOnly, !facts.uncertain, !facts.suspended,
              !facts.reconciling, !facts.hasPendingSend,
              !facts.sendingWhileRunning else { return false }
        switch self {
        case .streaming: return true
        case .idle, .cached, .loading, .syncing, .reconnecting, .submitting,
             .stopping, .needsLogin: return false
        }
    }

    /// 只有在核对确认后台不存在这条之后才允许重发。
    func allowsResend(_ facts: ChatFacts) -> Bool {
        guard !facts.readOnly, !facts.uncertain, !facts.suspended,
              facts.pendingAbsent, facts.hasPendingSend else { return false }
        switch self {
        case .idle: return true
        case .cached, .loading, .syncing, .reconnecting, .submitting, .streaming,
             .stopping, .needsLogin: return false
        }
    }

    /// 迁移合法性：只拦「接线错误」级别的边，不拦业务分支。
    ///
    /// 登录失效后相位必须被**重新加载**才能离开——不可能凭空接上一条流、
    /// 也不可能直接进入「正在发送」。允许的边：重新加载（loading/syncing/cached）、
    /// 落回静止态、以及再次判定失效。
    static func isPlausibleTransition(from: ChatPhase, to: ChatPhase) -> Bool {
        guard case .needsLogin = from else { return true }
        switch to {
        case .idle, .loading, .syncing, .cached, .needsLogin: return true
        case .reconnecting, .submitting, .streaming, .stopping: return false
        }
    }
}


// MARK: - Single-run identity and completion policy (build179)

/// Immutable scope captured before any awaited network operation. A callback
/// cannot authorize a new send merely because its session still has a matching
/// title or its HTTP request returned successfully.
struct ChatRunContext: Equatable, Sendable {
    let instanceScope: String
    let sessionID: String
    let runID: String
    let revision: UInt

    func matches(instanceScope: String, sessionID: String, runID: String?,
                 revision: UInt, suspended: Bool) -> Bool {
        !suspended && !self.runID.isEmpty
            && self.instanceScope == instanceScope && self.sessionID == sessionID
            && self.runID == runID && self.revision == revision
    }
}

/// Every terminal handler and queued dispatch uses this one policy. STOP has
/// priority over an in-flight SSE terminal, and a verified reply cannot reset
/// a separately persisted user pause or a recovery safety pause.
enum ChatRuntimeCoordinator {
    enum TerminalAction: Equatable {
        case verifyStop
        case keepLocked
        case finishWithoutDispatch
        case finishAndDispatch
    }

    static func terminalAction(stopPending: Bool, sameRun: Bool,
                               terminalFrame: Bool, finalHistoryConfirmed: Bool,
                               successful: Bool, uncertain: Bool, userPaused: Bool,
                               recoveryPaused: Bool) -> TerminalAction {
        if stopPending { return .verifyStop }
        guard sameRun, terminalFrame, finalHistoryConfirmed, !uncertain else {
            return .keepLocked
        }
        return !successful || userPaused || recoveryPaused
            ? .finishWithoutDispatch : .finishAndDispatch
    }
}
