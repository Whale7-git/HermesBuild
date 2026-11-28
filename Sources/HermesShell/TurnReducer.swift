import Foundation

/// 驱动 `Turn` 的输入。每一条都对应一个**已经发生的事实**，不是意图。
///
/// 这个划分很重要：旧代码里「我想重连」「我听说断了」「我猜可能好了」混在
/// 同一批布尔里，于是谁最后写谁赢。事件只能陈述事实，怎么反应由 `reduce` 决定，
/// 而且同一个事件永远得到同一个结果。
enum TurnEvent: Equatable, Sendable {
    /// 用户按下发送，POST 即将离开设备。
    case submitStarted(key: String, text: String, attachments: [ChatAttachmentPayload], at: Date)
    /// 服务端受理（200 或 202 replay 都算），给出 run id。
    case submitAccepted(runID: String)
    /// 服务端**明确拒绝**（4xx）。这是终局，不再重试。
    case submitRejected(Turn.Sending.Rejection)
    /// 传输层失败：不知道服务端有没有受理。
    case submitTransportFailure(at: Date)
    /// SSE 送来一个事件，带游标。
    case streamEvent(id: String)
    /// SSE 无法继续（404/410/断开），需要改走 GET。
    case streamUnavailable
    /// `GET /v1/runs/{id}` 报终态。
    case statusTerminal(RunTerminalStatus, output: String?)
    /// `GET /v1/runs/{id}` 报还在跑。
    case statusAlive
    /// 协议的 `unknown`：owner 中途重启（G2）。
    case statusUnknownByOwnerRestart
    /// 用户通过 `resolve-unknown` 确认了这一轮。
    case resolvedByUser(outcome: RunTerminalStatus)
    /// 网关排水，轮询看到 `shutdown_requested_at`（G9）。
    case shutdownRequested(at: Date)
    /// 正文已经补进历史。
    case backfillCompleted
    /// 会话切换/登出/显式重置。
    case reset
}

/// 状态转移要求外部做的事。`reduce` 自己**不执行**任何 IO。
enum TurnEffect: Equatable, Sendable {
    case attachStream(runID: String, lastEventID: String?)
    case pollStatus(runID: String, afterSeconds: Double)
    /// 用**同一个 key** 重放（G1）。不是新请求。
    case replaySubmission(key: String, afterSeconds: Double)
    case backfillHistory(runID: String)
    case notifyUser(TurnNotice)
}

/// 允许让用户看见的提示。刻意很短：用户不需要看内部状态名。
enum TurnNotice: Equatable, Sendable {
    /// 唯一需要用户处理的 POST 情形：ledger 已过期，重放会变成新一轮。
    case submissionExpiredWithoutAnswer
    /// 网关排水导致这一轮被打断（G3/G9），不是客户端的错。
    case interruptedByGateway
    /// 协议要求的确认：owner 重启后的 unknown 需要用户确认才能继续（G2）。
    case needsUnknownResolution(runID: String)
}

struct TurnTransition: Equatable, Sendable {
    let turn: Turn
    let effects: [TurnEffect]
}

/// `Turn` 的唯一状态转移函数。
///
/// 纯函数，没有 IO、没有定时器、没有对 `NativeChatModel` 的依赖。这样它可以被
/// 单元测试穷举，也可以在切换期间和旧逻辑并行跑做影子对比。
///
/// 每条分支都指回官方条款（`audit/refactor-official-guidance.md`）。
enum TurnReducer {

    static func reduce(_ turn: Turn, _ event: TurnEvent) -> TurnTransition {
        switch event {

        // MARK: 发送

        case let .submitStarted(key, text, attachments, at):
            let sending = Turn.Sending(submissionKey: key, text: text,
                                       attachments: attachments,
                                       attempts: 1, lastAttemptAt: at, rejection: nil)
            return .init(turn: .sending(sending), effects: [])

        case let .submitAccepted(runID):
            // 200 与 202 replay 在这里汇合：两者都给了权威 run id（G1）。
            // 客户端不需要知道它是不是重放——`Idempotency-Replayed` 只用于日志。
            return .init(turn: .running(.init(runID: runID, lastEventID: nil,
                                              terminal: nil, output: nil,
                                              shutdownRequestedAt: nil,
                                              unresolvedByOwnerRestart: false)),
                         effects: [.attachStream(runID: runID, lastEventID: nil)])

        case .submitRejected:
            // 明确被拒 = 服务端没受理（permission_denied 明确无 reservation，G8）。
            // 回到 idle，让用户看到真实原因；不保留 sending，避免误以为还在等。
            //
            // TODO(S5 文案收敛): 这里和「幂等窗口过期」共用同一条 notice，
            // 语义并不准确——拒绝是确定性失败，过期是「重放不再安全」。
            // 两者都该有各自的措辞，但不该在这一阶段改文案。
            return .init(turn: .idle,
                         effects: [.notifyUser(.submissionExpiredWithoutAnswer)])

        case let .submitTransportFailure(at):
            guard case .sending(var sending) = turn else { return .init(turn: turn, effects: []) }
            sending.attempts += 1
            sending.lastAttemptAt = at
            // 幂等窗口内：同 key 重放是安全的，且服务端不会执行第二次（G1）。
            // 超过 24h：重放会真的新建一轮，所以必须停下来问用户（G1）。
            if sending.canReplay {
                let delay = backoffSeconds(failures: sending.attempts - 1)
                return .init(turn: .sending(sending),
                             effects: [.replaySubmission(key: sending.submissionKey, afterSeconds: delay)])
            }
            return .init(turn: .idle,
                         effects: [.notifyUser(.submissionExpiredWithoutAnswer)])

        // MARK: 实时

        case let .streamEvent(id):
            guard case .running(var running) = turn else { return .init(turn: turn, effects: []) }
            running.lastEventID = id
            return .init(turn: .running(running), effects: [])

        case .streamUnavailable:
            // SSE 没了不代表任务没了。转 GET，这不产生任何用户提示（G6）。
            guard case .running(let running) = turn, running.terminal == nil else {
                return .init(turn: turn, effects: [])
            }
            return .init(turn: turn, effects: [.pollStatus(runID: running.runID, afterSeconds: 1)])

        // MARK: 状态核对

        case let .statusTerminal(outcome, output):
            guard case .running(var running) = turn else { return .init(turn: turn, effects: []) }
            // 终态一到，这一轮在协议上就结束了（G3/G4）。正文可能还没落史，
            // 但对「能不能发下一条」没有任何影响。
            running.terminal = outcome
            if let output { running.output = output }
            running.unresolvedByOwnerRestart = false
            var effects: [TurnEffect] = [.backfillHistory(runID: running.runID)]
            if outcome == .interrupted {
                // 网关关闭导致的中断是外部原因，值得说一次（G3）。
                effects.append(.notifyUser(.interruptedByGateway))
            }
            return .init(turn: .running(running), effects: effects)

        case .statusAlive:
            guard case .running(let running) = turn, running.terminal == nil else {
                return .init(turn: turn, effects: [])
            }
            return .init(turn: turn, effects: [.pollStatus(runID: running.runID, afterSeconds: 60)])

        case .statusUnknownByOwnerRestart:
            guard case .running(var running) = turn, running.terminal == nil else {
                return .init(turn: turn, effects: [])
            }
            // 协议的 unknown 只有一个来源，而且**不是终态**：
            // 后续轮次要等用户/客户端用 resolve-unknown 确认（G2）。
            running.unresolvedByOwnerRestart = true
            return .init(turn: .running(running),
                         effects: [.notifyUser(.needsUnknownResolution(runID: running.runID))])

        case let .resolvedByUser(outcome):
            guard case .running(var running) = turn else { return .init(turn: turn, effects: []) }
            running.unresolvedByOwnerRestart = false
            running.terminal = outcome
            return .init(turn: .running(running),
                         effects: [.backfillHistory(runID: running.runID)])

        case let .shutdownRequested(at):
            guard case .running(var running) = turn else { return .init(turn: turn, effects: []) }
            // 只是预告：状态仍是 running，不改变发送判定（G9）。
            running.shutdownRequestedAt = at
            return .init(turn: .running(running),
                         effects: [.pollStatus(runID: running.runID, afterSeconds: 5)])

        // MARK: 收尾

        case .backfillCompleted:
            guard case .running(let running) = turn, running.terminal != nil else {
                return .init(turn: turn, effects: [])
            }
            // 正文补齐之后，这一轮才算彻底收完。
            return .init(turn: .idle, effects: [])

        case .reset:
            return .init(turn: .idle, effects: [])
        }
    }

    /// 重放退避。`failures` 是第几次失败，从 1 开始——第一次失败等 1 秒。
    /// 503 带 `Retry-After` 时由引擎覆盖这个值（G7）。
    static func backoffSeconds(failures: Int) -> Double {
        let ladder: [Double] = [1, 2, 5, 15, 60, 120]
        let index = max(0, min(failures - 1, ladder.count - 1))
        return ladder[index]
    }
}
