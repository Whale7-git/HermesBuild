import Foundation

extension ModelTests {
    /// S1 的契约：发送判定只能从四个具名事实派生，历史新鲜度不得参与。
    ///
    /// 这些断言存在的理由很具体：`RunFinalizer` 之前零测试覆盖，
    /// 于是 238→242 四个版本反复修、CI 一直绿、锁还在。拆分 `uncertain`
    /// 是同一类改动，没有断言就等于没有改动。
    @MainActor static func sendGateTests() {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
            checks += 1
            precondition(condition(), label)
        }

        // MARK: 默认状态
        expect(!SendGate().blocksNewTurn, "a fresh gate must allow sending")
        expect(!SendGate().uncertain, "a fresh gate is not uncertain")
        expect(!SendGate().isRunning, "a fresh gate is not running")
        expect(!SendGate().isSettled, "a fresh gate has nothing settled")

        // MARK: A 类 —— 服务端 Run 状态
        expect(SendGate(run: .active(runID: "r1")).blocksNewTurn,
               "an active Run blocks sending")
        expect(SendGate(run: .active(runID: "r1")).isRunning,
               "an active Run reports running")
        expect(SendGate(run: .unknown(runID: "r1")).blocksNewTurn,
               "an unconfirmable Run blocks sending")
        expect(SendGate(run: .unknown(runID: nil)).blocksNewTurn,
               "an unconfirmable Run without an id blocks sending")

        let settled = SendGate(run: .settled(runID: "r1", outcome: .completed))
        expect(!settled.blocksNewTurn, "a settled Run allows the next turn")
        expect(settled.isSettled, "a settled Run with no pending work is settled")
        expect(!settled.isRunning, "a settled Run is not running")

        // 四种终态都算结束，不能只认 completed
        for outcome in [RunTerminalStatus.completed, .failed, .cancelled, .interrupted] {
            expect(!SendGate(run: .settled(runID: "r1", outcome: outcome)).blocksNewTurn,
                   "terminal \(outcome) allows the next turn")
        }

        // MARK: B 类 —— 本地发送事务
        expect(SendGate(pending: .reconciling).blocksNewTurn,
               "an in-flight reconciliation blocks sending")
        expect(SendGate(pending: .awaitingDecision).blocksNewTurn,
               "an unknown POST outcome blocks sending")
        expect(SendGate(pending: .acceptedUnretired).blocksNewTurn,
               "an accepted-but-unretired queue row blocks sending")
        expect(!SendGate(pending: .absent).blocksNewTurn,
               "a proven-absent POST allows a safe resend")

        // 已结算 + 投递仍未知 = 不许发（结算的是上一轮，这笔还在飞）
        expect(SendGate(run: .settled(runID: "r1", outcome: .completed),
                        pending: .awaitingDecision).blocksNewTurn,
               "a settled Run does not clear an unsettled POST")

        // MARK: C 类 —— 本地持久化
        expect(SendGate(store: .degraded(reason: "disk")).blocksNewTurn,
               "a degraded store blocks sending")
        expect(SendGate(run: .settled(runID: "r1", outcome: .completed),
                        store: .degraded(reason: "disk")).blocksNewTurn,
               "a degraded store blocks sending even after a settle")
        expect(!SendGate(store: .degraded(reason: "disk")).isSettled,
               "a degraded store is never settled")

        // MARK: D 类 —— 历史新鲜度必须被忽略（本次重构的核心）
        expect(!SendGate(historyFresh: false).blocksNewTurn,
               "stale history alone must not block sending")
        expect(!SendGate(run: .settled(runID: "r1", outcome: .completed),
                         historyFresh: false).blocksNewTurn,
               "a settled Run with unsynced history must still allow sending")
        expect(!SendGate(run: .settled(runID: "r1", outcome: .completed),
                         pending: .none,
                         store: .ok,
                         historyFresh: false).uncertain,
               "unsynced history must not read as uncertain")
        // 反向：历史已同步也不能掩盖真正的阻塞
        expect(SendGate(run: .unknown(runID: "r1"), historyFresh: true).blocksNewTurn,
               "fresh history must not hide an unconfirmable Run")

        // MARK: 兼容派生
        expect(SendGate(run: .unknown(runID: "r1")).uncertain,
               "uncertain mirrors blocksNewTurn for a live Run")
        expect(!SendGate(historyFresh: false).uncertain,
               "uncertain no longer mirrors history freshness")

        // MARK: 影子对比
        expect(SendGateShadow.mismatch(legacyBlocksSend: false, gate: SendGate()) == nil,
               "shadow must not report a mismatch when both agree")

        // 旧逻辑因为历史没追上也锁（D 冒充 A），新逻辑放行 —— 这正是要观察的分歧
        let settledStale = SendGate(run: .settled(runID: "r1", outcome: .completed),
                                    historyFresh: false)
        guard let mismatch = SendGateShadow.mismatch(legacyBlocksSend: true,
                                                     gate: settledStale) else {
            preconditionFailure("shadow must flag legacy=blocked vs derived=allowed")
        }
        checks += 1
        expect(mismatch.legacy && !mismatch.derived, "mismatch records both sides")
        expect(mismatch.diagnosticLine.contains("historyFresh=false"),
               "the diagnostic line carries the deciding facts")
        expect(!mismatch.diagnosticLine.contains("r1"),
               "the diagnostic line must not leak the run id")

        // 两者都拒绝时不算分歧
        expect(SendGateShadow.mismatch(legacyBlocksSend: true,
                                       gate: SendGate(run: .active(runID: "r1"))) == nil,
               "shadow must not disagree when both block")

        print("PASS sendgate (\(checks) checks)")
    }
}
