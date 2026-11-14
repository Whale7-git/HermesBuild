import Foundation

/// 用户对某条「需要处理」任务的本地确认。
///
/// 确认绑定 `(sessionID, signal, observedAt)`：`observedAt` 是这个问题被观察到
/// 的那一刻，也就是它的身份。同一个 `observedAt` 说明还是同一个问题，确认继续
/// 有效；一旦聊天页重新观察出新的 `observedAt`，说明问题又出现了，确认自动失效。
///
/// 这样做的好处是**写入侧零改动**：聊天页照旧把 `recoveryIssue` 写进
/// `sessionTaskObservations`，任务中心只在展示时按确认过滤。不存在「删了又被写
/// 回来」的循环。
///
/// 只有 `recoveryIssue` 可确认。审批必须等服务端确认、待核对发送必须核对历史，
/// 本地消隐会伪造服务端状态。
struct TaskAcknowledgement: Codable, Equatable, Sendable {
    let sessionID: String
    let signal: SessionTaskSignal
    /// 被确认的那次观察时间（epoch 秒）。
    let observedAt: Double
    /// 用户点「标记已处理」的时间（epoch 秒），用于淘汰。
    let acknowledgedAt: Double

    /// 保留期：与 GitHub `is:done` 的三个月一致。
    static let retention: TimeInterval = 90 * 86_400

    /// 唯一可确认的信号。
    static func isAcknowledgeable(_ signal: SessionTaskSignal) -> Bool {
        signal == .recoveryIssue
    }

    /// 这条确认是否覆盖该会话当前的观察。
    ///
    /// 三个条件必须同时成立：会话相同、当前信号里确实有该问题、观察时间没变。
    /// 时间用 `Double` 原值比较，不做秒级截断——同一秒内的两次观察是两个问题。
    func covers(sessionID otherID: String, observation: SessionTaskObservation) -> Bool {
        guard otherID == sessionID else { return false }
        guard observation.signals.contains(signal) else { return false }
        return observation.observedAt == observedAt
    }
}

// MARK: - 展示侧过滤

extension TaskAcknowledgement {

    /// 按确认过滤后仍应展示的会话。
    ///
    /// 只影响展示，不修改任何持久化信号。信号真的消失了，会话本就不会出现在
    /// 任务中心；信号仍在但用户已确认，才由这里过滤掉。
    static func visibleSessionIDs(
        observations: [String: SessionTaskObservation],
        acknowledgements: [TaskAcknowledgement]
    ) -> Set<String> {
        var visible = Set<String>()
        for (sessionID, observation) in observations {
            let covered = acknowledgements.contains {
                $0.covers(sessionID: sessionID, observation: observation)
            }
            if !covered { visible.insert(sessionID) }
        }
        return visible
    }

    /// 撤销一条确认。
    static func removing(
        _ acknowledgement: TaskAcknowledgement,
        from all: [TaskAcknowledgement]
    ) -> [TaskAcknowledgement] {
        all.filter { $0 != acknowledgement }
    }

    /// 淘汰超过保留期的确认。恰好到期仍保留。
    static func pruning(_ all: [TaskAcknowledgement], now: TimeInterval) -> [TaskAcknowledgement] {
        all.filter { now - $0.acknowledgedAt <= retention }
    }

    /// 删除某个会话的全部确认（会话被删时调用）。
    static func removingAll(
        sessionID: String,
        from all: [TaskAcknowledgement]
    ) -> [TaskAcknowledgement] {
        all.filter { $0.sessionID != sessionID }
    }
}
