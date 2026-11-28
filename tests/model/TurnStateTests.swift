import Foundation

extension ModelTests {
    /// P1 的契约：三个 case 的状态机，以及它和官方协议的对应关系。
    @MainActor static func turnStateTests() {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
            checks += 1
            precondition(condition(), label)
        }

        // MARK: 空闲
        expect(Turn.idle.allowsNewMessage, "an idle turn allows a new message")
        expect(!Turn.idle.awaitsReplyBackfill, "an idle turn backfills nothing")
        expect(Turn.idle.runID == nil && Turn.idle.submissionKey == nil,
               "an idle turn carries no identity")

        // MARK: sending —— G1 幂等
        func sending(attempts: Int = 1,
                     lastAttemptAt: Date = Date(),
                     rejection: Turn.Sending.Rejection? = nil) -> Turn.Sending {
            .init(submissionKey: "key-1", text: "hi", attachments: [],
                  attempts: attempts, lastAttemptAt: lastAttemptAt,
                  rejection: rejection)
        }

        expect(!Turn.sending(sending()).allowsNewMessage,
               "an in-flight POST blocks a second one")
        expect(Turn.sending(sending()).submissionKey == "key-1",
               "the submission key survives for replay")
        expect(sending().canReplay, "a plain network failure can be replayed")
        expect(!sending(lastAttemptAt: Date().addingTimeInterval(-25 * 60 * 60)).canReplay,
               "past the 24h ledger window a replay is not safe")
        expect(sending(lastAttemptAt: Date().addingTimeInterval(-23 * 60 * 60)).canReplay,
               "inside the 24h window a replay is still safe")

        // 明确拒绝不能重试 —— G1(409 conflict) / G8(permission_denied)
        for kind in [Turn.Sending.Rejection.Kind.permissionDenied,
                     .idempotencyKeyConflict,
                     .unauthenticated,
                     .malformedRequest(status: 400)] {
            let rejected = sending(rejection: .init(kind: kind, status: 409))
            expect(!rejected.canReplay, "\(kind) must not be replayed")
        }

        // MARK: running —— G4 终态与 output
        var running = Turn.Running(runID: "run-1", lastEventID: nil,
                                   terminal: nil, output: nil,
                                   shutdownRequestedAt: nil,
                                   unresolvedByOwnerRestart: false)
        let live = Turn.running(running)
        expect(!live.allowsNewMessage, "a live Run blocks a new message")
        expect(!live.awaitsReplyBackfill, "a live Run is not a backfill case")
        expect(live.runID == "run-1", "the run id is exposed for SSE attach")

        // G1：断线重连靠游标，不靠用户
        running.lastEventID = "42"
        expect(Turn.running(running).runID == "run-1",
               "reconnecting keeps the same run identity")

        // G4：终态到手，这一轮在协议上就结束了
        running.terminal = .completed
        running.output = "final answer"
        let settled = Turn.running(running)
        expect(settled.allowsNewMessage,
               "a settled Run no longer blocks the next message")
        expect(settled.awaitsReplyBackfill,
               "a settled Run still awaits the reply backfill")

        // 四种终态都算结束
        for outcome in [RunTerminalStatus.completed, .failed, .cancelled, .interrupted] {
            var copy = running
            copy.terminal = outcome
            expect(Turn.running(copy).awaitsReplyBackfill,
                   "terminal \(outcome) starts a backfill")
        }

        // G2：unknown 只有一个来源；它不是终态
        var unknown = Turn.Running(runID: "run-2", lastEventID: nil,
                                   terminal: nil, output: nil,
                                   shutdownRequestedAt: nil,
                                   unresolvedByOwnerRestart: true)
        expect(!Turn.running(unknown).allowsNewMessage,
               "an owner-restart unknown keeps later turns waiting")
        expect(!Turn.running(unknown).awaitsReplyBackfill,
               "unknown is not a terminal, so it is not a backfill")
        unknown.unresolvedByOwnerRestart = false
        unknown.terminal = .interrupted
        expect(Turn.running(unknown).allowsNewMessage,
               "interrupted settles the turn and releases sending")

        // MARK: 交叉不变量
        // 历史/正文从来不是输入：只有 terminal 决定 backfill，只有 case 决定能否发送。
        var withOutputNoTerminal = Turn.Running(runID: "run-3", lastEventID: nil,
                                                terminal: nil, output: "产生了一半的正文",
                                                shutdownRequestedAt: nil,
                                                unresolvedByOwnerRestart: false)
        expect(!Turn.running(withOutputNoTerminal).allowsNewMessage,
               "partial output does not make a live Run sendable")
        expect(!Turn.running(withOutputNoTerminal).awaitsReplyBackfill,
               "partial output is not a backfill")
        withOutputNoTerminal.terminal = .completed
        expect(Turn.running(withOutputNoTerminal).awaitsReplyBackfill &&
               Turn.running(withOutputNoTerminal).allowsNewMessage,
               "terminal + output is a backfill and releases sending")
        expect(Turn.running(withOutputNoTerminal).output == "产生了一半的正文",
               "the captured output survives for the backfill")

        print("PASS turnstate (\(checks) checks)")
    }
}
