import Foundation

/// 一轮对话的全部状态。三个 case，互斥，组合不出非法态。
///
/// 取代原先可以任意组合的一批示意标志（`uncertain` / `readOnly` /
/// `sendingWhileRunning` / `pendingAbsent` …）。那段历史里出现过
/// 「reconnecting 与 running 同时为真」这种无法用类型表达的组合，于是四个谓词
/// 各自把同一批布尔重新组合一遍，集合互不一致——这是状态同步反复出错的根源。
///
/// 每一条设计都能指回官方文档（`audit/refactor-official-guidance.md`）：
///
/// - **G1** 幂等：`Sending` 靠「同一个 key 重放」收敛，不是靠用户核对。
///   官方：identical retry 返回原 `run_id` + 202，ledger 保留 24 小时。
/// - **G2** `unknown` 只有一个来源（owner 中途重启），`404` 不是 `unknown`。
/// - **G3** `interrupted` 是网关重启的必然终态，不必为「重启后还在跑」设计路径。
/// - **G4** 终态与 `output` 必须本地持久化，status 只在终态后短暂保留。
/// - **G6** SSE 天生支持 attach/detach，断线重连是正常路径，不产生提示、不锁发送。
enum Turn: Equatable, Sendable {
    case idle
    case sending(Sending)
    case running(Running)

    /// 一笔已经发出、结果还没确定的 POST。
    ///
    /// 它在 24 小时内可以安全地用**同一个 `submissionKey`** 重放（G1）。
    /// 超过 ledger 保留期后重放会真的新建一轮，所以 `expired` 是唯一需要
    /// 让用户知道的 POST 状态。
    struct Sending: Equatable, Sendable {
        let submissionKey: String
        let text: String
        let attachments: [ChatAttachmentPayload]
        var attempts: Int
        var lastAttemptAt: Date
        /// 服务端**明确拒绝**（4xx，含 409 `permission_denied` /
        /// `idempotency_key_conflict`）。这类失败重试无益，必须换处理方式。
        var rejection: Rejection?

        struct Rejection: Equatable, Sendable {
            enum Kind: Equatable, Sendable {
                /// 跨 surface 绑会话：官方明确「no reservation is kept，
                /// an exact retry answers 409 again」（G8）。
                case permissionDenied
                /// 同一个 key 配了不同 payload，是客户端 bug（G1）。
                case idempotencyKeyConflict
                /// 401/403。
                case unauthenticated
                /// 其余 4xx（400 invalid_params、422 等）。
                case malformedRequest(status: Int)
            }
            let kind: Kind
            let status: Int?
        }

        /// ledger 的 24 小时边界（G1）。超过之后同 key 重放不再安全。
        static let replayWindow: TimeInterval = 24 * 60 * 60

        var isReplayWindowExpired: Bool {
            Date().timeIntervalSince(lastAttemptAt) > Self.replayWindow
        }

        /// 是否还能靠重放收敛。明确拒绝和窗口过期都不行。
        var canReplay: Bool {
            rejection == nil && !isReplayWindowExpired
        }
    }

    /// 一轮已被服务端受理的 Run。
    ///
    /// 注意这里**没有**「历史是否同步」字段：历史同步是另一件事，它只影响
    /// 正文显示，永远不参与「能不能发下一条」。
    struct Running: Equatable, Sendable {
        let runID: String
        /// SSE 断点续传游标（G6）。nil 表示还没收到过事件。
        var lastEventID: String?

        /// 已经拿到、但正文可能还没写进服务端历史的终态（G4）。
        ///
        /// 一旦非 nil，这一轮在协议意义上就结束了：用户可以继续聊天，
        /// 正文由历史同步在后台补齐。status 本身在终态后只短暂保留，
        /// 所以这个值必须落盘，不能只留在内存里。
        var terminal: RunTerminalStatus?
        /// 终态附带的服务端最终回复（`GET /v1/runs/{id}` 的 `output`）。
        /// 历史滞后时这是唯一的内容证据。
        var output: String?

        /// 网关正在排水时轮询能看到这个字段，`status` 仍是 `running`（G9）。
        /// 它不是异常，也不改变发送判定。
        var shutdownRequestedAt: Date?

        /// 协议意义上的 `unknown`：owner 中途重启（G2）。
        ///
        /// **只有这一个来源**。客户端查不到（404、超时、断网）不是 `unknown`，
        /// 那种情况要用幂等重放或历史补齐，不能写进这里。
        var unresolvedByOwnerRestart: Bool

        var isFinished: Bool { terminal != nil }
    }

    // MARK: - 派生

    /// 是否允许发送一条新的普通消息。
    ///
    /// 只有两种阻塞：正在发送（避免重复），或有一轮在跑（服务端忙）。
    /// 历史同步、连接状态、notice 文案都不在这里。
    var allowsNewMessage: Bool {
        switch self {
        case .idle: return true
        case .sending, .running: return false
        }
    }

    /// 这一轮是否已经结束但正文还没落史——决定要不要显示「同步中」。
    ///
    /// **只影响显示**，不进 `allowsNewMessage`。
    var awaitsReplyBackfill: Bool {
        if case .running(let running) = self { return running.terminal != nil }
        return false
    }

    var runID: String? {
        if case .running(let running) = self { return running.runID }
        return nil
    }

    var submissionKey: String? {
        if case .sending(let sending) = self { return sending.submissionKey }
        return nil
    }

    /// 服务端报的最终回复。历史滞后时这是唯一的内容证据（G4）。
    var output: String? {
        if case .running(let running) = self { return running.output }
        return nil
    }
}
