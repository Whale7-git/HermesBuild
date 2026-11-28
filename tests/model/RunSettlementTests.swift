import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// 专项回归：RunFinalizer 的结算判定。
//
// 这里钉死一条架构契约：**经过身份校验的服务端终态本身就是「任务已结束」的
// 证据，历史只能反驳它，不能反过来要求历史先匹配才允许结算。**
//
// 之前 `canSettle` 硬要求 `activeRunEvidence == .absent`，而 `/v1/runs/{id}`
// 过期后永久 404 → 客户端写下 unresolved 墓碑 → 证据永远 `.unknown` → 会话
// 永久锁死（#168）。T01/T08 就是这两条边界。

extension ModelTests {
    @MainActor static func runSettlementTests() throws {
        var failures: [String] = []
        var checks = 0

        func snap(_ json: String, runStatusUnknown: Bool = false) throws -> ChatSnapshot {
            try ChatSnapshot(data: Data(json.utf8), runStatusUnknown: runStatusUnknown)
        }

        // helper: 一个"历史尚无本轮回复"的最小快照
        func emptyHistory(active: String? = nil, unknown: Bool = false, readOnly: Bool = false) throws -> ChatSnapshot {
            var fields: [String: Any] = ["session_id": "s1", "messages": []]
            if let active { fields["active_stream_id"] = active }
            if readOnly { fields["read_only"] = true }
            let data = try JSONSerialization.data(withJSONObject: ["session": fields])
            return try ChatSnapshot(data: data, runStatusUnknown: unknown)
        }

        func expect(_ condition: Bool, _ label: String) {
            checks += 1
            if !condition { failures.append(label) }
        }

        let receipt = ActiveTurnRecovery(runID: "run-1", historyEnd: 0, knownIDs: [],
                                        text: "你好", attachmentPaths: [])

        // MARK: - T01 已确认 completed，历史一直不匹配，也要能结算

        // 墓碑（status 过期后的 .unknown）不得再阻塞结算
        expect(RunFinalizer.canSettle([try emptyHistory(unknown: true)],
                                      sessionID: "s1", runID: "run-1", receipt: receipt,
                                      outcome: .completed, requireReply: false),
               "T01 tombstoned snapshot must not block settlement")

        // 历史尚未写入回复，但服务端给了 output —— 内容已可靠取得，允许结算
        expect(RunFinalizer.canSettle([try emptyHistory(unknown: true)],
                                      sessionID: "s1", runID: "run-1", receipt: receipt,
                                      outcome: .completed, requireReply: true,
                                      recoveredOutput: "这是最终回复"),
               "T01 completed with recovered output settles despite unmatched history")

        // 没有任何内容证据时保持保守：不结算，避免把空回复当完成
        expect(!RunFinalizer.canSettle([try emptyHistory(unknown: true)],
                                       sessionID: "s1", runID: "run-1", receipt: receipt,
                                       outcome: .completed, requireReply: true),
               "T01 completed with no content evidence must stay locked")

        // MARK: - 服务端还报这个 Run 活着 → 必须继续锁

        expect(!RunFinalizer.canSettle([try emptyHistory(active: "run-1")],
                                       sessionID: "s1", runID: "run-1", receipt: receipt,
                                       outcome: .completed, requireReply: false,
                                       recoveredOutput: "有内容"),
               "an alive report for this exact Run must still block")

        // 别的 Run 活着与本轮终态无关
        expect(RunFinalizer.canSettle([try emptyHistory(active: "run-2")],
                                      sessionID: "s1", runID: "run-1", receipt: receipt,
                                      outcome: .completed, requireReply: false,
                                      recoveredOutput: "有内容"),
               "another Run being alive must not block this Run's settlement")

        // MARK: - 非 completed 终态：终态即结束

        for outcome in [RunTerminalStatus.failed, .cancelled, .interrupted] {
            expect(RunFinalizer.canSettle([try emptyHistory(unknown: true)],
                                          sessionID: "s1", runID: "run-1", receipt: receipt,
                                          outcome: outcome, requireReply: true),
                   "\(outcome) settles from terminal status alone")
        }

        // MARK: - T08 身份与归属必须仍然校验

        expect(!RunFinalizer.canSettle([try emptyHistory(unknown: true)],
                                       sessionID: "s2", runID: "run-1", receipt: receipt,
                                       outcome: .completed, requireReply: false,
                                       recoveredOutput: "内容"),
               "a different session must never settle")

        expect(!RunFinalizer.canSettle([try emptyHistory(unknown: true, readOnly: true)],
                                       sessionID: "s1", runID: "run-1", receipt: receipt,
                                       outcome: .completed, requireReply: false,
                                       recoveredOutput: "内容"),
               "a read-only snapshot must never settle")

        // receipt 属于另一轮 → 不得用它的证据
        let otherReceipt = ActiveTurnRecovery(runID: "run-9", historyEnd: 0, knownIDs: [],
                                             text: "别的", attachmentPaths: [])
        expect(!RunFinalizer.canSettle([try emptyHistory(unknown: true)],
                                       sessionID: "s1", runID: "run-1", receipt: otherReceipt,
                                       outcome: .completed, requireReply: false,
                                       recoveredOutput: "内容"),
               "a receipt for another Run must not authorize settlement")

        // MARK: - isRunReportedActive 的语义

        expect(isRunReportedActive(try emptyHistory(active: "run-1"), runID: "run-1"),
               "same Run alive is reported active")
        expect(!isRunReportedActive(try emptyHistory(active: "run-2"), runID: "run-1"),
               "another Run must not read as active for this Run")
        expect(!isRunReportedActive(try emptyHistory(unknown: true), runID: "run-1"),
               "an unknown/tombstoned snapshot must not read as active")

        if failures.isEmpty {
            print("PASS runsettlement (\(checks) checks)")
        } else {
            for failure in failures { print("FAIL runsettlement: \(failure)") }
            exit(1)
        }
    }
}
