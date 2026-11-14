import Foundation

// W5「标记已处理」纯逻辑测试。
//
// 核心规则：确认绑定 (sessionID, signal, observedAt)。同一问题（observedAt
// 不变）确认后不再显示；问题重现（observedAt 变了）确认自动失效。
// 只有 recoveryIssue 可确认——审批和待核对必须等服务端事实。

var failures: [String] = []
var checks = 0

func expect(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition { failures.append(message) }
}

func expectEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String) {
    checks += 1
    if lhs != rhs { failures.append("\(message): 期望 \(rhs)，实际 \(lhs)") }
}

let t1: Double = 1_700_000_000
let t2: Double = 1_700_000_100

func observation(_ signals: Set<SessionTaskSignal>, at time: Double) -> SessionTaskObservation {
    SessionTaskObservation(signals: signals, observedAt: Date(timeIntervalSince1970: time))
}

// MARK: - 只有 recoveryIssue 可确认

expect(TaskAcknowledgement.isAcknowledgeable(.recoveryIssue), "恢复问题可确认")
expect(!TaskAcknowledgement.isAcknowledgeable(.waitingForApproval), "审批不可确认")
expect(!TaskAcknowledgement.isAcknowledgeable(.needsVerification), "待核对不可确认")
expect(!TaskAcknowledgement.isAcknowledgeable(.running), "运行中不可确认")
expect(!TaskAcknowledgement.isAcknowledgeable(.stopping), "停止中不可确认")

// MARK: - 确认后隐藏

let ack = TaskAcknowledgement(sessionID: "s1", signal: .recoveryIssue,
                              observedAt: t1, acknowledgedAt: t1 + 10)
let sameObservation = observation([.recoveryIssue], at: t1)
expect(ack.covers(sessionID: "s1", observation: sameObservation),
       "同一 observedAt 的恢复问题应被确认覆盖")

// 会话不同，不覆盖。
expect(!ack.covers(sessionID: "s2", observation: observation([.recoveryIssue], at: t1)),
       "别的会话不受影响")

// MARK: - 问题重现则确认失效

let reappeared = observation([.recoveryIssue], at: t2)
expect(!ack.covers(sessionID: "s1", observation: reappeared),
       "observedAt 变化后确认必须失效")

// MARK: - 信号消失则确认不再需要

let cleared = observation([], at: t1)
expect(!ack.covers(sessionID: "s1", observation: cleared),
       "信号已消失时确认不生效（任务本就不显示）")

// 同一 observedAt 但信号集合不含 recoveryIssue。
let otherSignal = observation([.running], at: t1)
expect(!ack.covers(sessionID: "s1", observation: otherSignal),
       "信号集合不含该恢复问题时确认不生效")

// MARK: - 观察时间精度：不做截断

// 相差 0.001 秒必须视为不同问题，否则同一秒内的两次观察会被错误合并。
let near = observation([.recoveryIssue], at: t1 + 0.001)
expect(!ack.covers(sessionID: "s1", observation: near),
       "观察时间有差异即视为新问题，不做截断")

// MARK: - 过滤：任务中心展示侧

let observations: [String: SessionTaskObservation] = [
    "s1": observation([.recoveryIssue], at: t1),
    "s2": observation([.recoveryIssue], at: t1),
    "s3": observation([.waitingForApproval], at: t1),
]
let acks: [TaskAcknowledgement] = [
    TaskAcknowledgement(sessionID: "s1", signal: .recoveryIssue,
                        observedAt: t1, acknowledgedAt: t1 + 10),
]
let visible = TaskAcknowledgement.visibleSessionIDs(
    observations: observations, acknowledgements: acks)
expect(!visible.contains("s1"), "已确认的恢复问题从展示中移除")
expect(visible.contains("s2"), "未确认的同类问题仍展示")
expect(visible.contains("s3"), "审批永远展示，不受确认影响")

// MARK: - 撤销

let afterUndo = TaskAcknowledgement.removing(
    TaskAcknowledgement(sessionID: "s1", signal: .recoveryIssue,
                        observedAt: t1, acknowledgedAt: t1 + 10),
    from: acks)
expectEqual(afterUndo.count, 0, "撤销后记录被删除")
let visibleAfterUndo = TaskAcknowledgement.visibleSessionIDs(
    observations: observations, acknowledgements: afterUndo)
expect(visibleAfterUndo.contains("s1"), "撤销后任务重新出现")

// MARK: - 淘汰：90 天

let now = t1 + 100 * 86_400
let old = TaskAcknowledgement(sessionID: "s1", signal: .recoveryIssue,
                              observedAt: t1, acknowledgedAt: t1)
let fresh = TaskAcknowledgement(sessionID: "s2", signal: .recoveryIssue,
                                observedAt: t1, acknowledgedAt: now - 10 * 86_400)
let pruned = TaskAcknowledgement.pruning([old, fresh], now: now)
expectEqual(pruned.count, 1, "超过 90 天的确认被淘汰")
expectEqual(pruned.first?.sessionID, "s2", "保留未过期的确认")

// 恰好 90 天应保留（边界）。
let exactly90 = TaskAcknowledgement(sessionID: "s3", signal: .recoveryIssue,
                                    observedAt: t1, acknowledgedAt: now - 90 * 86_400)
expectEqual(TaskAcknowledgement.pruning([exactly90], now: now).count, 1,
            "恰好 90 天的确认仍保留")

// MARK: - P1：确认过滤的粒度是信号，不是整个会话

// 同一会话里同时有「恢复问题」（已确认）和「等待审批」（未确认）。
// 旧实现按 sessionID 整条隐藏，会把仍需处理的审批一起藏掉。
do {
    let obs = observation([.recoveryIssue, .waitingForApproval], at: t1)
    let summary = SessionTaskSummary(sessionID: "s-mixed",
                                     signals: [.recoveryIssue, .waitingForApproval])
    let ack = TaskAcknowledgement(sessionID: "s-mixed", signal: .recoveryIssue,
                                  observedAt: t1, acknowledgedAt: t1)
    let filtered = SessionTaskCenter.filteringAcknowledged(
        [summary], observations: ["s-mixed": obs], acknowledgements: [ack])
    expectEqual(filtered.count, 1, "确认一个问题后，会话不会整条消失")
    expectEqual(filtered.first?.signals ?? [], Set([.waitingForApproval]),
                "只剔除已确认的那个信号，仍需处理的审批保留")
}

// 会话里只有一个信号且已确认 → 整条隐藏。
do {
    let obs = observation([.recoveryIssue], at: t1)
    let summary = SessionTaskSummary(sessionID: "s-only", signals: [.recoveryIssue])
    let ack = TaskAcknowledgement(sessionID: "s-only", signal: .recoveryIssue,
                                  observedAt: t1, acknowledgedAt: t1)
    let filtered = SessionTaskCenter.filteringAcknowledged(
        [summary], observations: ["s-only": obs], acknowledgements: [ack])
    expectEqual(filtered.count, 0, "信号全部被确认后整条隐藏")
}

// 观察时间变了（问题重新出现）→ 旧确认失效，必须重新展示。
do {
    let obs = observation([.recoveryIssue], at: t1 + 60)
    let summary = SessionTaskSummary(sessionID: "s-re", signals: [.recoveryIssue])
    let staleAck = TaskAcknowledgement(sessionID: "s-re", signal: .recoveryIssue,
                                       observedAt: t1, acknowledgedAt: t1)
    let filtered = SessionTaskCenter.filteringAcknowledged(
        [summary], observations: ["s-re": obs], acknowledgements: [staleAck])
    expectEqual(filtered.count, 1, "问题重现（新 observedAt）后旧确认失效，任务重新出现")
}

// 没有确认记录时原样返回，不做任何重排或丢弃。
do {
    let summary = SessionTaskSummary(sessionID: "s-none", signals: [.recoveryIssue])
    let filtered = SessionTaskCenter.filteringAcknowledged(
        [summary], observations: [:], acknowledgements: [])
    expectEqual(filtered, [summary], "无确认记录时摘要原样返回")
}

// MARK: - 结果

if failures.isEmpty {
    print("_PASS taskack \(checks) checks")
} else {
    for failure in failures { print("FAIL taskack: \(failure)") }
    print("_FAIL taskack \(failures.count)/\(checks) checks failed")
    exit(1)
}
