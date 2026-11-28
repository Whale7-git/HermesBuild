import Foundation

extension ModelTests {
    /// `TurnReducer` 的转移表：同一事件永远得到同一结果，且副作用是可枚举的。
    @MainActor static func turnReducerTests() {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
            checks += 1
            precondition(condition(), label)
        }

        let now = Date()

        // MARK: 发送 → 受理
        let started = TurnReducer.reduce(.idle,
            .submitStarted(key: "k1", text: "hi", attachments: [], at: now))
        expect(started.turn.submissionKey == "k1", "submitStarted creates a sending turn")
        expect(started.effects.isEmpty, "starting a POST needs no follow-up effect")

        let accepted = TurnReducer.reduce(started.turn, .submitAccepted(runID: "run-1"))
        expect(accepted.turn.runID == "run-1", "acceptance produces the run identity")
        expect(accepted.effects == [.attachStream(runID: "run-1", lastEventID: nil)],
               "acceptance attaches the stream")

        // MARK: 明确拒绝
        let rejected = TurnReducer.reduce(started.turn,
            .submitRejected(.init(kind: .permissionDenied, status: 409)))
        expect(rejected.turn == .idle, "an explicit refusal returns to idle")
        expect(rejected.effects == [.notifyUser(.submissionExpiredWithoutAnswer)],
               "an explicit refusal tells the user once")

        // MARK: 传输失败 —— G1 的两种结局
        let retry = TurnReducer.reduce(started.turn, .submitTransportFailure(at: now))
        expect(retry.turn.submissionKey == "k1",
               "a transport failure keeps the same key for replay")
        guard case .replaySubmission(let key, let delay)? = retry.effects.first else {
            preconditionFailure("a transport failure must schedule a same-key replay")
        }
        checks += 1
        expect(key == "k1", "the replay reuses the original key, never a new one")
        expect(delay == 1, "the first replay waits one second")

        // 超过 24h：重放会变成新一轮，必须停下来问用户
        let old = Turn.Sending(submissionKey: "k1", text: "hi", attachments: [],
                               attempts: 1,
                               lastAttemptAt: now.addingTimeInterval(-25 * 60 * 60),
                               rejection: nil)
        let expired = TurnReducer.reduce(.sending(old), .submitTransportFailure(at: now))
        expect(expired.turn == .idle, "past the ledger window the turn stops")
        expect(expired.effects == [.notifyUser(.submissionExpiredWithoutAnswer)],
               "past the ledger window the user is told once")

        // MARK: 流
        let withCursor = TurnReducer.reduce(accepted.turn, .streamEvent(id: "42"))
        guard case .running(let running) = withCursor.turn else {
            preconditionFailure("a stream event must keep the running turn")
        }
        checks += 1
        expect(running.lastEventID == "42", "the event cursor is kept for reconnect")

        let fellBack = TurnReducer.reduce(withCursor.turn, .streamUnavailable)
        expect(fellBack.effects == [.pollStatus(runID: "run-1", afterSeconds: 1)],
               "a dead stream falls back to a status GET, not to a user prompt")
        expect(fellBack.turn == withCursor.turn,
               "a dead stream does not change the turn state")

        // MARK: 终态 —— G3/G4
        for outcome in [RunTerminalStatus.completed, .failed, .cancelled] {
            let terminal = TurnReducer.reduce(withCursor.turn, .statusTerminal(outcome, output: "done"))
            guard case .running(let done) = terminal.turn else {
                preconditionFailure("terminal must stay a running turn until backfill")
            }
            checks += 2
            expect(done.terminal == outcome, "terminal \(outcome) is recorded")
            expect(terminal.turn.allowsNewMessage,
                   "terminal \(outcome) releases the next message immediately")
            expect(terminal.effects.contains(.backfillHistory(runID: "run-1")),
                   "terminal \(outcome) schedules the reply backfill")
        }

        // interrupted 额外提示一次：网关关闭是外部原因
        let interrupted = TurnReducer.reduce(withCursor.turn, .statusTerminal(.interrupted, output: nil))
        expect(interrupted.effects.contains(.notifyUser(.interruptedByGateway)),
               "a gateway interrupt is surfaced once")
        expect(interrupted.turn.allowsNewMessage,
               "an interrupted turn releases the next message")

        // 正文补齐后才真正回到 idle
        let done = TurnReducer.reduce(withCursor.turn, .statusTerminal(.completed, output: "x"))
        let backfilled = TurnReducer.reduce(done.turn, .backfillCompleted)
        expect(backfilled.turn == .idle, "backfill completion finishes the turn")
        expect(backfilled.turn.allowsNewMessage, "an idle turn allows sending")

        // 没有终态时 backfill 不该提前收尾
        let premature = TurnReducer.reduce(withCursor.turn, .backfillCompleted)
        expect(premature.turn != .idle,
               "backfill cannot finish a turn the server has not ended")

        // MARK: G2 协议的 unknown
        let unknown = TurnReducer.reduce(withCursor.turn, .statusUnknownByOwnerRestart)
        guard case .running(let stalled) = unknown.turn else {
            preconditionFailure("an owner-restart unknown keeps the turn")
        }
        checks += 1
        expect(stalled.unresolvedByOwnerRestart,
               "unknown is recorded as owner-restart, the only source")
        expect(!unknown.turn.allowsNewMessage,
               "an owner-restart unknown keeps later turns waiting (protocol)")
        expect(unknown.effects.contains(.notifyUser(.needsUnknownResolution(runID: "run-1"))),
               "the user is asked to resolve it")

        let resolved = TurnReducer.reduce(unknown.turn, .resolvedByUser(outcome: .interrupted))
        expect(resolved.turn.allowsNewMessage,
               "resolving the unknown settles the turn")

        // MARK: G9 排水预告
        let draining = TurnReducer.reduce(withCursor.turn, .shutdownRequested(at: now))
        expect(draining.effects == [.pollStatus(runID: "run-1", afterSeconds: 5)],
               "a shutdown request only tightens polling")
        expect(draining.turn.allowsNewMessage == false,
               "a shutdown request does not release sending by itself")

        // MARK: 重置
        expect(TurnReducer.reduce(accepted.turn, .reset).turn == .idle,
               "reset returns to idle")

        // MARK: 退避阶梯
        expect(TurnReducer.backoffSeconds(attempts: 1) == 1, "backoff starts at 1s")
        expect(TurnReducer.backoffSeconds(attempts: 6) == 120, "backoff caps at 120s")
        expect(TurnReducer.backoffSeconds(attempts: 99) == 120, "backoff never exceeds the cap")

        print("PASS turnreducer (\(checks) checks)")
    }
}
