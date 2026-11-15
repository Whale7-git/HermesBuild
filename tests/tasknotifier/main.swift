import Foundation

// W1 通知纯逻辑层测试。只测 TaskNotificationPlanner 的决策，
// 不触碰 UserNotifications——那部分在 Linux 上不可用。

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

let allOn = TaskNotificationPlanner.Settings()
let approvalOff = TaskNotificationPlanner.Settings(approvalEnabled: false)
let clarifyOff = TaskNotificationPlanner.Settings(clarifyEnabled: false)
let finishedOff = TaskNotificationPlanner.Settings(finishedEnabled: false)
let recoveryOff = TaskNotificationPlanner.Settings(recoveryEnabled: false)

// MARK: - 审批

// 在别的会话，应发。
let elsewhere = TaskNotificationPlanner.approval(
    requestID: "req1", sessionID: "s1", title: "会话一",
    settings: allOn, foregroundSessionID: "s2")
expect(elsewhere != nil, "审批：在别的会话应当发通知")
expectEqual(elsewhere?.kind, .approvalPending, "审批：类型")
expectEqual(elsewhere?.stableID, "approval.s1.req1", "审批：稳定标识")
expectEqual(elsewhere?.sessionTitle, "会话一", "审批：标题透传")

// 正在该会话，不发。
let same = TaskNotificationPlanner.approval(
    requestID: "req1", sessionID: "s1", title: "会话一",
    settings: allOn, foregroundSessionID: "s1")
expect(same == nil, "审批：正在该会话时不发")

// App 已到后台时，currentSessionID 仍可能等于该会话；此时不能误抑制。
let sameSessionInBackground = TaskNotificationPlanner.approval(
    requestID: "req1", sessionID: "s1", title: "会话一",
    settings: allOn, foregroundSessionID: "s1", appActive: false)
expect(sameSessionInBackground != nil, "审批：后台同会话仍发")

// 没有前台会话，应发。
let noForeground = TaskNotificationPlanner.approval(
    requestID: "req1", sessionID: "s1", title: "会话一",
    settings: allOn, foregroundSessionID: nil)
expect(noForeground != nil, "审批：无前台会话时应当发")

// 同一 requestID 两次，标识必须相同（系统据此替换，不堆叠）。
let first = TaskNotificationPlanner.approval(
    requestID: "req1", sessionID: "s1", title: "会话一",
    settings: allOn, foregroundSessionID: nil)
let second = TaskNotificationPlanner.approval(
    requestID: "req1", sessionID: "s1", title: "会话一",
    settings: allOn, foregroundSessionID: nil)
expectEqual(first?.stableID, second?.stableID, "审批：同一 requestID 标识稳定")

// 不同 requestID，标识必须不同。
let otherReq = TaskNotificationPlanner.approval(
    requestID: "req2", sessionID: "s1", title: "会话一",
    settings: allOn, foregroundSessionID: nil)
expect(first?.stableID != otherReq?.stableID, "审批：不同 requestID 标识不同")

// requestID 缺失时退化，仍要发。
let noReq = TaskNotificationPlanner.approval(
    requestID: nil, sessionID: "s1", title: "会话一",
    settings: allOn, foregroundSessionID: nil)
expect(noReq != nil, "审批：缺 requestID 仍应发")
expectEqual(noReq?.stableID, "approval.s1", "审批：缺 requestID 时退化标识")

// 开关关闭，不发。
let approvalDisabled = TaskNotificationPlanner.approval(
    requestID: "req1", sessionID: "s1", title: "会话一",
    settings: approvalOff, foregroundSessionID: nil)
expect(approvalDisabled == nil, "审批：开关关闭时不发")

let clarify = TaskNotificationPlanner.clarify(
    requestID: "clarify-1", sessionID: "s1", title: "会话一",
    settings: allOn, foregroundSessionID: nil)
expectEqual(clarify?.kind, .clarifyPending, "补充信息：独立通知类型")
expectEqual(clarify?.stableID, "clarify.s1.clarify-1", "补充信息：稳定标识")
expectEqual(TaskNotificationPlanner.requestIdentifier(
    kind: "clarify", requestID: "clarify-1", sessionID: "s1",
    instanceID: "", accountScope: ""), "clarify.s1.clarify-1",
    "补充信息：解析后可精确删除")
let clarifySame = TaskNotificationPlanner.clarify(
    requestID: "clarify-1", sessionID: "s1", title: "会话一",
    settings: allOn, foregroundSessionID: "s1")
expect(clarifySame == nil, "补充信息：前台同会话抑制")
let clarifyBackground = TaskNotificationPlanner.clarify(
    requestID: "clarify-1", sessionID: "s1", title: "会话一",
    settings: allOn, foregroundSessionID: "s1", appActive: false)
expect(clarifyBackground != nil, "补充信息：后台同会话仍发")
let clarifyDisabled = TaskNotificationPlanner.clarify(
    requestID: "clarify-1", sessionID: "s1", title: "会话一",
    settings: clarifyOff, foregroundSessionID: nil)
expect(clarifyDisabled == nil, "补充信息：开关关闭时不发")

// MARK: - 完成

let finished = TaskNotificationPlanner.finished(
    runID: "run1", sessionID: "s1", title: "会话一",
    settings: allOn, foregroundSessionID: "s2")
expect(finished != nil, "完成：在别的会话应当发")
expectEqual(finished?.kind, .runFinished, "完成：类型")
expectEqual(finished?.stableID, "finished.s1.run1", "完成：稳定标识")

let finishedSameSession = TaskNotificationPlanner.finished(
    runID: "run1", sessionID: "s1", title: "会话一",
    settings: allOn, foregroundSessionID: "s1")
expect(finishedSameSession == nil, "完成：正在该会话时不发")

// 同一 run 两次，标识相同。
let finishedAgain = TaskNotificationPlanner.finished(
    runID: "run1", sessionID: "s1", title: "会话一",
    settings: allOn, foregroundSessionID: nil)
expectEqual(finished?.stableID, finishedAgain?.stableID, "完成：同一 run 标识稳定")

// 不同 run，标识不同。
let otherRun = TaskNotificationPlanner.finished(
    runID: "run2", sessionID: "s1", title: "会话一",
    settings: allOn, foregroundSessionID: nil)
expect(finished?.stableID != otherRun?.stableID, "完成：不同 run 标识不同")

// runID 缺失时退化。
let noRun = TaskNotificationPlanner.finished(
    runID: nil, sessionID: "s1", title: "会话一",
    settings: allOn, foregroundSessionID: nil)
expect(noRun != nil, "完成：缺 runID 仍应发")
expectEqual(noRun?.stableID, "finished.s1", "完成：缺 runID 时退化标识")

let finishedDisabled = TaskNotificationPlanner.finished(
    runID: "run1", sessionID: "s1", title: "会话一",
    settings: finishedOff, foregroundSessionID: nil)
expect(finishedDisabled == nil, "完成：开关关闭时不发")

// MARK: - 恢复

let recovery = TaskNotificationPlanner.recovery(
    sessionID: "s1", title: "会话一",
    settings: allOn, foregroundSessionID: "s2")
expect(recovery != nil, "恢复：在别的会话应当发")
expectEqual(recovery?.kind, .recoveryIssue, "恢复：类型")
expectEqual(recovery?.stableID, "recovery.s1", "恢复：稳定标识")

let recoverySame = TaskNotificationPlanner.recovery(
    sessionID: "s1", title: "会话一",
    settings: allOn, foregroundSessionID: "s1")
expect(recoverySame == nil, "恢复：正在该会话时不发")

// 同一会话两次，标识相同（不重复轰炸）。
let recoveryAgain = TaskNotificationPlanner.recovery(
    sessionID: "s1", title: "会话一",
    settings: allOn, foregroundSessionID: nil)
expectEqual(recovery?.stableID, recoveryAgain?.stableID, "恢复：同会话标识稳定")

let recoveryDisabled = TaskNotificationPlanner.recovery(
    sessionID: "s1", title: "会话一",
    settings: recoveryOff, foregroundSessionID: nil)
expect(recoveryDisabled == nil, "恢复：开关关闭时不发")

// MARK: - 跨类型隔离

let ids: Set<String> = [first?.stableID, finished?.stableID, recovery?.stableID]
    .compactMap { $0 }.reduce(into: Set<String>()) { $0.insert($1) }
expectEqual(ids.count, 3, "三类通知的标识互不相同")

// MARK: - 空会话标题降级

let emptyTitle = TaskNotificationPlanner.approval(
    requestID: "req1", sessionID: "s1", title: "",
    settings: allOn, foregroundSessionID: nil)
expect(emptyTitle != nil, "审批：空标题仍应发")
expectEqual(emptyTitle?.sessionTitle, "未命名会话", "审批：空标题降级为占位文案")

// MARK: - 通知点击导航意图（P1）

do {
    let nav = NotificationNavigation()
    expect(nav.take() == nil, "导航：没有意图时返回 nil，调用方不应改变界面")

    nav.open(sessionID: "s-a")
    expectEqual(nav.pendingSessionID, "s-a", "导航：意图被记录下来")
    expectEqual(nav.take(), "s-a", "导航：取走意图")
    expect(nav.take() == nil, "导航：同一意图不会被消费两次")

    // 空 id 不能产生导航意图，否则会跳到一个不存在的会话。
    nav.open(sessionID: "")
    expect(nav.take() == nil, "导航：空会话标识不产生意图")

    // 连点两条通知，最后一条生效。
    nav.open(sessionID: "s-old")
    nav.open(sessionID: "s-new")
    expectEqual(nav.take(), "s-new", "导航：只保留最新意图，用户最后点的那条才作数")
}

do {
    let nav = NotificationNavigation()
    nav.open(sessionID: "cold-start")
    expectEqual(nav.pendingSessionID, "cold-start", "Cold start retains intent before list load")
    expect(!nav.consume(sessionID: "stale"), "A stale navigation callback cannot consume the latest target")
    expect(nav.consume(sessionID: "cold-start"), "Consume after target exists")
    expect(nav.pendingSessionID == nil, "Consumed once")
}

// MARK: - Scoped Hermes ownership and collision safety

let scopedA = TaskNotificationPlanner.approval(
    requestID: "same-request", sessionID: "same-session", title: "A",
    settings: allOn, foregroundSessionID: nil,
    instanceID: "host-A", accountScope: "account-1")
let scopedB = TaskNotificationPlanner.approval(
    requestID: "same-request", sessionID: "same-session", title: "B",
    settings: allOn, foregroundSessionID: nil,
    instanceID: "host-B", accountScope: "account-1")
let scopedOtherAccount = TaskNotificationPlanner.approval(
    requestID: "same-request", sessionID: "same-session", title: "A",
    settings: allOn, foregroundSessionID: nil,
    instanceID: "host-A", accountScope: "account-2")
expect(scopedA?.stableID != scopedB?.stableID,
       "same session/request in another host must not replace notification")
expect(scopedA?.stableID != scopedOtherAccount?.stableID,
       "retired account must not overwrite new-account notifications")
expectEqual(scopedA?.instanceID, "host-A", "notification preserves originating host")
expectEqual(scopedA?.accountScope, "account-1", "notification preserves originating account")

do {
    let nav = NotificationNavigation()
    nav.open(sessionID: "same-session", instanceID: "host-A", accountScope: "account-1")
    let target = nav.pendingTarget!
    expect(target.isScoped, "new notification has verifiable ownership")
    expect(!nav.consume(target: .init(instanceID: "host-B",
                                     accountScope: "account-1",
                                     sessionID: "same-session")),
           "same session ID from another host must not consume notification")
    expect(nav.consume(target: target), "correct exact target can consume notification")
    expect(nav.pendingTarget == nil, "scoped notification is consumed exactly once")
}

// MARK: - 结果

if failures.isEmpty {
    print("_PASS tasknotifier \(checks) checks")
} else {
    for failure in failures { print("FAIL tasknotifier: \(failure)") }
    print("_FAIL tasknotifier \(failures.count)/\(checks) checks failed")
    exit(1)
}
