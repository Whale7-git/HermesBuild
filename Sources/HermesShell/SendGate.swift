import Foundation

/// 服务端状态是唯一权威；客户端每一件「还没弄清楚的事」都必须单独具名。
///
/// 取代 `NativeChatModel.uncertain` 这个被 78 处赋值共用的开关。它原本同时装着四种
/// 完全不同的事实，而其中「历史读取失败」最频繁、也最无害，却能把「任务真的还在跑」
/// 和「POST 结果未知」的锁一起长出来——于是长回合结束后用户永远发不出下一条消息，
/// 反复点「核对状态」也不会好，因为下一次历史刷新会重新把锁置上。
///
/// 这里只保存四个**事实**，不保存任何结论：
///
/// - `run`     服务端对这个 Run 的权威状态（原 A 类）
/// - `pending` 本地这笔 POST 的处置状态（原 B 类）
/// - `store`   本地持久化是否可用（原 C 类）
/// - `historyFresh` 历史是否新鲜（原 D 类，**刻意不参与发送判定**）
///
/// 发送判定只能从这四项派生，不允许任何模块单独把一个布尔翻成「锁」。
struct SendGate: Equatable, Sendable {
    /// 服务端对这个 Run 说过的话。
    ///
    /// `.unknown` 与 `.none` 的区别是刻意的：前者表示「有一个 Run，但我现在确认不了它
    /// 的死活」（断网、超时、404、服务端自己报 unknown），后者表示「根本没有在跑的 Run」。
    /// 两者混淆会让「从未发过消息」的会话也被要求核对状态。
    enum RunState: Equatable, Sendable {
        case none
        case active(runID: String)
        case unknown(runID: String?)
        case settled(runID: String, outcome: RunTerminalStatus)
    }

    /// 本地这笔发送事务走到哪一步了。
    ///
    /// `acceptedUnretired` 单独存在是有代价换来的：队列消息已经被服务端受理，
    /// 只是本地队列行删不掉。它看起来像「已送达」，但如果为了省事把它当成
    /// 「可以重发」，队列会再 POST 一次，而服务端那一轮其实已经在跑了。
    enum PendingState: Equatable, Sendable {
        case none
        /// GET 核对在途，窗口内禁止并发发送。
        case reconciling
        /// POST 投递结果未知，等用户决定（重发 / 放弃）。
        case awaitingDecision
        /// 已受理，但本地队列行尚未退休。
        case acceptedUnretired
        /// 已由服务端权威证明这条没送到，可以安全重发。
        case absent
    }

    /// 本地持久化是否可用。写盘失败不能让「重启后能恢复」这个前提失效。
    enum StoreHealth: Equatable, Sendable {
        case ok
        case degraded(reason: String)
    }

    var run: RunState = .none
    var pending: PendingState = .none
    var store: StoreHealth = .ok
    /// 历史是否已经追上最新终态。**只影响显示，不影响能不能发。**
    var historyFresh = false

    init(run: RunState = .none,
         pending: PendingState = .none,
         store: StoreHealth = .ok,
         historyFresh: Bool = false) {
        self.run = run
        self.pending = pending
        self.store = store
        self.historyFresh = historyFresh
    }

    // MARK: - 判定

    /// 是否允许发送一条**新的**普通消息。
    ///
    /// 顺序无关紧要，每一项都是独立的否决权：
    /// - 本地写盘坏了 → 拒绝（重启会丢证据）
    /// - 有一笔 POST 还没结算 → 拒绝（可能重复）
    /// - 服务端说 Run 还活着，或确认不了死活 → 拒绝
    ///
    /// `historyFresh` 不在这里。历史没追上、历史同步失败、SSE 已断开，
    /// 都不构成拒绝发送的理由——任务书五明确要求这几项允许发送。
    var blocksNewTurn: Bool {
        if store != .ok { return true }

        switch pending {
        case .reconciling, .awaitingDecision, .acceptedUnretired:
            return true
        case .none, .absent:
            break
        }

        switch run {
        case .active, .unknown:
            return true
        case .none, .settled:
            return false
        }
    }

    /// 兼容既有 UI 的只读派生。**不再是可写状态**。
    ///
    /// 语义收窄为「有没有真实阻塞」：以前历史读取失败也算 true，
    /// 现在只有 run/pending/store 三项能影响它。
    var uncertain: Bool { blocksNewTurn }

    /// 是否有一轮任务正在（据服务端所说）执行。
    var isRunning: Bool {
        if case .active = run { return true }
        return false
    }

    /// 已结算且没有任何未决事务——这一轮彻底结束了。
    var isSettled: Bool {
        guard case .settled = run else { return false }
        switch pending {
        case .none, .absent: return store == .ok
        case .reconciling, .awaitingDecision, .acceptedUnretired: return false
        }
    }
}

// MARK: - 影子对比

/// 拆分期间用新旧两套判定同时算，只记录分歧、不改变行为。
///
/// 这是整个重构的安全网：任何我没想到的状态组合，都会先以一条日志的形式出现，
/// 而不是变成用户手里发不出去的消息。
enum SendGateShadow {
    struct Mismatch: Equatable, Sendable {
        let legacy: Bool
        let derived: Bool
        let run: SendGate.RunState
        let pending: SendGate.PendingState
        let store: SendGate.StoreHealth
        let historyFresh: Bool

        /// 只含状态名，不含消息正文——可以安全写进运行时日志。
        var diagnosticLine: String {
            "gate-shadow legacy=\(legacy) derived=\(derived) "
                + "run=\(run.label) pending=\(pending.label) "
                + "store=\(store.label) historyFresh=\(historyFresh)"
        }
    }

    /// 返回 nil 表示新旧一致。
    static func mismatch(legacyBlocksSend: Bool, gate: SendGate) -> Mismatch? {
        let derived = gate.blocksNewTurn
        guard legacyBlocksSend != derived else { return nil }
        return Mismatch(legacy: legacyBlocksSend, derived: derived,
                        run: gate.run, pending: gate.pending,
                        store: gate.store, historyFresh: gate.historyFresh)
    }
}

// MARK: - 日志标签

extension SendGate.RunState {
    /// 只输出状态名，不输出 runID（日志里不需要，也避免跨会话串味）。
    var label: String {
        switch self {
        case .none: return "none"
        case .active: return "active"
        case .unknown: return "unknown"
        case .settled(_, let outcome): return "settled(\(outcome))"
        }
    }
}

extension SendGate.PendingState {
    var label: String {
        switch self {
        case .none: return "none"
        case .reconciling: return "reconciling"
        case .awaitingDecision: return "awaitingDecision"
        case .acceptedUnretired: return "acceptedUnretired"
        case .absent: return "absent"
        }
    }
}

extension SendGate.StoreHealth {
    var label: String {
        switch self {
        case .ok: return "ok"
        case .degraded: return "degraded"
        }
    }
}
