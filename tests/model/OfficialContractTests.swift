import Foundation

/// G1–G9 的官方条款门禁（`audit/refactor-official-guidance.md`，每条都能指回原文）。
///
/// 与 `TurnStateTests` 的分工：那个文件测状态机的形状，这个文件测「有没有偏离官方协议」。
/// 每条断言都以 `Gx:` 开头，失败时能直接看出违反了哪一条。
///
/// 编译：`tests/model/*.swift` 由 `tests/run_container.sh` 的 `model` 套件一起编译
/// （`-swift-version 5 -warnings-as-errors`）。本机没有 Swift 工具链，编译由 CI 验证。
/// 运行：需要在 `tests/model/main.swift` 里调用一次 `officialContractTests()`；
/// 本任务禁止修改现有 .swift，这行留给集成方补。
extension ModelTests {
    @MainActor static func officialContractTests() {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
            checks += 1
            precondition(condition(), label)
        }

        func sending(key: String = "key-1",
                     attempts: Int = 1,
                     lastAttemptAt: Date = Date(),
                     rejection: Turn.Sending.Rejection? = nil) -> Turn.Sending {
            .init(submissionKey: key, text: "hi", attachments: [],
                  attempts: attempts, lastAttemptAt: lastAttemptAt,
                  rejection: rejection)
        }

        func running(runID: String = "run-1",
                     lastEventID: String? = nil,
                     terminal: RunTerminalStatus? = nil,
                     output: String? = nil,
                     shutdownRequestedAt: Date? = nil,
                     unknown: Bool = false) -> Turn.Running {
            .init(runID: runID, lastEventID: lastEventID, terminal: terminal,
                  output: output, shutdownRequestedAt: shutdownRequestedAt,
                  unresolvedByOwnerRestart: unknown)
        }

        /// 存储属性的真实集合。`Mirror` 是这里唯一可靠的结构证据：它能证明
        /// 某个概念**没有**字段可以表达，而不只是「当前代码没这么用」。
        /// （用闭包而非 `\.label`：`Mirror.Child` 是元组，元组不支持 key path。）
        func storedLabels<T>(_ value: T) -> [String] {
            Mirror(reflecting: value).children.compactMap { $0.label }
        }

        func notices(_ effects: [TurnEffect]) -> [TurnNotice] {
            effects.compactMap { effect in
                if case .notifyUser(let notice) = effect { return notice }
                return nil
            }
        }

        /// `isFinished` 只挂在 `Turn.Running` 上，`Turn` 不转发它——「结束」是 Run 的属性。
        func finished(_ turn: Turn) -> Bool {
            if case .running(let live) = turn { return live.isFinished }
            return false
        }

        func replayKeys(_ effects: [TurnEffect]) -> [String] {
            effects.compactMap { effect in
                if case .replaySubmission(let key, _) = effect { return key }
                return nil
            }
        }

        // MARK: - G1 幂等：同一个 key 重放，24h 是硬边界

        expect(Turn.Sending.replayWindow == 24 * 60 * 60,
               "G1: the ledger window is exactly 24h, not a client-side guess")
        expect(sending(lastAttemptAt: Date().addingTimeInterval(-23 * 3600)).canReplay,
               "G1: inside the window a lost response is recovered by replay, not by the user")
        // 边界两侧各留几秒余量：判断用的是 `Date()`，贴着 -24h 构造会因执行耗时抖动。
        expect(sending(lastAttemptAt: Date().addingTimeInterval(-(Turn.Sending.replayWindow + 1)))
                .isReplayWindowExpired,
               "G1: one second past the window is already expired")
        expect(!sending(lastAttemptAt: Date().addingTimeInterval(-(Turn.Sending.replayWindow - 5)))
                .isReplayWindowExpired,
               "G1: five seconds before the boundary the key is still reserved")
        expect(!sending(lastAttemptAt: Date().addingTimeInterval(-25 * 3600)).canReplay,
               "G1: past 24h a replay would really create a second run, so it must stop")

        // 四种「明确拒绝」都不能重放：400/401/403/409 都是终局，重试无益。
        let refusals: [(Turn.Sending.Rejection.Kind, Int?)] = [
            (.permissionDenied, 409),           // G8：跨 surface 绑会话
            (.idempotencyKeyConflict, 409),     // G1：同一个 key 配了不同 payload
            (.unauthenticated, 401),
            (.malformedRequest(status: 422), 422),
        ]
        for (kind, status) in refusals {
            expect(!sending(rejection: .init(kind: kind, status: status)).canReplay,
                   "G1: an explicit rejection (\(kind)) is final for this POST")
        }
        expect(!sending(rejection: .init(kind: .unauthenticated, status: nil)).canReplay,
               "G1: rejection without a status is still a rejection")

        // 重放必须复用同一把钥匙：turn 上能读出它，且只有一个身份字段。
        expect(Turn.sending(sending(key: "abc")).submissionKey == "abc",
               "G1: the key is readable from the turn, so a replay can reuse it verbatim")
        let sendingLabels = storedLabels(sending())
        expect(sendingLabels.filter { $0.lowercased().contains("key") } == ["submissionKey"],
               "G1: exactly one key field — a replay cannot accidentally mint a new one")
        expect(sendingLabels.filter {
            let lower = $0.lowercased()
            return lower.contains("terminal") || lower.contains("status")
        }.isEmpty,
               "G1: replay safety never depends on run status — the ledger answers for 24h either way")

        let started = TurnReducer.reduce(.idle,
                                         .submitStarted(key: "abc", text: "hi",
                                                        attachments: [], at: Date()))
        let lostResponse = TurnReducer.reduce(started.turn, .submitTransportFailure(at: Date()))
        expect(replayKeys(lostResponse.effects) == ["abc"],
               "G1: a lost response replays the identical key, not a fresh request")
        expect(lostResponse.turn.submissionKey == "abc" && !lostResponse.turn.allowsNewMessage,
               "G1: while the replay is in flight the POST stays outstanding")

        let expired = TurnReducer.reduce(
            Turn.sending(sending(lastAttemptAt: Date().addingTimeInterval(-25 * 3600))),
            .submitTransportFailure(at: Date()))
        expect(expired.turn == .idle && replayKeys(expired.effects).isEmpty,
               "G1: past the window the client abandons the POST instead of replaying it")
        expect(notices(expired.effects) == [.submissionExpiredWithoutAnswer],
               "G1: expiry is the one POST case the user has to be told about")

        // MARK: - G2 unknown 只有一个来源：owner 中途重启

        expect(RunTerminalStatus(rawValue: "unknown") == nil,
               "G2: `unknown` is not a terminal status — it has no place in RunTerminalStatus")
        let runFields: Set<String> = ["runID", "lastEventID", "terminal", "output",
                                      "shutdownRequestedAt", "unresolvedByOwnerRestart"]
        let runningLabels = storedLabels(running())
        expect(Set(runningLabels) == runFields,
               "G2: Running stores exactly these fields — adding one must be a deliberate contract change")
        let booleanFields = Mirror(reflecting: running()).children
            .filter { $0.value is Bool }.compactMap { $0.label }
        expect(booleanFields == ["unresolvedByOwnerRestart"],
               "G2: the only Bool on a Run is the owner-restart flag")
        let bannedLabels = ["unknown", "notfound", "missing", "tombstone",
                            "lookupfailed", "statusunknown", "unreachable", "absent"]
        expect(runningLabels.allSatisfy { label in
            let lower = label.lowercased()
            return !bannedLabels.contains { lower.contains($0) }
        }, "G2: no field can record `the client could not look it up` — 404/timeout are not unknown")

        let unknownTurn = Turn.running(running(unknown: true))
        expect(!unknownTurn.allowsNewMessage,
               "G2: an unresolved owner-restart unknown keeps later turns waiting")
        expect(!finished(unknownTurn) && !unknownTurn.awaitsReplyBackfill,
               "G2: unknown is not terminal, so it triggers neither settlement nor backfill")
        expect(unknownTurn.runID == "run-1",
               "G2: the run id survives so resolve-unknown can address it")

        // 除了那一个事件，任何输入都不许把 run 标成 unknown。
        let nonUnknownEvents: [TurnEvent] = [
            .streamEvent(id: "s:1"),
            .streamUnavailable,
            .statusAlive,
            .statusTerminal(.failed, output: nil),
            .shutdownRequested(at: Date()),
            .submitTransportFailure(at: Date()),
            .backfillCompleted,
        ]
        for event in nonUnknownEvents {
            let result = TurnReducer.reduce(Turn.running(running()), event)
            let flag: Bool
            if case .running(let after) = result.turn { flag = after.unresolvedByOwnerRestart }
            else { flag = false }
            expect(!flag, "G2: \(event) cannot mark a run unknown")
        }

        let settledBeforeUnknown = Turn.running(running(terminal: .completed, output: "done"))
        let lateUnknown = TurnReducer.reduce(settledBeforeUnknown, .statusUnknownByOwnerRestart)
        expect(lateUnknown.turn == settledBeforeUnknown && lateUnknown.effects.isEmpty,
               "G2: a terminal turn cannot be dragged back to unknown by a late poll")
        expect(TurnReducer.reduce(unknownTurn, .statusTerminal(.completed, output: "ok")).turn ==
               Turn.running(running(terminal: .completed, output: "ok")),
               "G2: a real terminal clears the owner-restart flag and settles the run")

        // MARK: - G3 interrupted 是终态；四种终态一律不算「在跟」

        for outcome in [RunTerminalStatus.completed, .failed, .cancelled, .interrupted] {
            let settledTurn = Turn.running(running(terminal: outcome))
            expect(finished(settledTurn) && settledTurn.allowsNewMessage,
                   "G3: \(outcome.rawValue) ends the run, so the next message is allowed")
            expect(settledTurn.awaitsReplyBackfill,
                   "G3: \(outcome.rawValue) still needs the history backfill")
        }
        expect(RunTerminalStatus(rawValue: "running") == nil,
               "G3: `running` can never be a settled status")

        let interrupted = TurnReducer.reduce(Turn.running(running()),
                                             .statusTerminal(.interrupted, output: nil))
        expect(notices(interrupted.effects) == [.interruptedByGateway],
               "G3: gateway shutdown is reported exactly once, as an external interruption")
        expect(interrupted.turn.allowsNewMessage,
               "G3: interrupted with no output is still settled — the body comes from history")
        let resurrected = TurnReducer.reduce(interrupted.turn, .statusAlive)
        expect(resurrected.turn == interrupted.turn && resurrected.effects.isEmpty,
               "G3: a gateway restart never leaves a settled run looking alive")

        // MARK: - G4 status 会被清理；terminal + output 才是本地真相

        let settledNoBody = Turn.running(running(terminal: .completed, output: nil))
        expect(finished(settledNoBody) && settledNoBody.allowsNewMessage,
               "G4: the terminal alone ends the turn, before any body arrives")
        expect(settledNoBody.output == nil,
               "G4: a missing output reads as nil, not as an empty answer")
        let settledWithBody = Turn.running(running(terminal: .completed, output: "final"))
        expect(settledWithBody.output == "final",
               "G4: the captured output is readable from the turn")
        expect(Turn.idle.output == nil && Turn.sending(sending()).output == nil,
               "G4: output only exists on a Run, never on idle/sending")

        // 正文的到达与否不影响结算：四种终态 × 三种 output 结果必须完全一致。
        let bodyVariants: [String?] = [nil, "", "half"]
        let allowMatrix = bodyVariants.map { body in
            Turn.running(running(terminal: .completed, output: body)).allowsNewMessage
        }
        expect(Set(allowMatrix) == [true],
               "G4: whether the body is present never decides the send gate")
        for body in bodyVariants {
            expect(!Turn.running(running(output: body)).allowsNewMessage,
                   "G4: output without a terminal does not mean the run is over")
        }

        // 关键：没有正文的 status 轮询不许抹掉已拿到的 output（它是唯一内容证据）。
        expect(TurnReducer.reduce(settledWithBody, .statusTerminal(.completed, output: nil)).turn.output == "final",
               "G4: a later poll without a body cannot erase the captured output")
        expect(TurnReducer.reduce(settledWithBody, .backfillCompleted).turn == .idle,
               "G4: once the body is in history the turn is fully closed")
        expect(runningLabels.contains("terminal") && runningLabels.contains("output"),
               "G4: status and body are stored fields, so a journal can persist them instead of re-polling")

        // MARK: - G5 SSE keepalive 是注释，不能被当成事件

        // 逐步求值再断言：`feed` 是 mutating，写进 autoclosure 里会让检查顺序变得含糊。
        var parser = SSEParser()
        let commentLine = parser.feed(line: ": keepalive")
        expect(commentLine == nil, "G5: a `:` comment line never becomes a frame")
        let commentBlockEnd = parser.feed(line: "")
        expect(commentBlockEnd == nil, "G5: a keepalive-only block emits nothing")
        _ = parser.feed(line: "event: token")
        _ = parser.feed(line: "data: {\"text\":\"a\"}")
        let afterComment = parser.feed(line: "")
        expect(afterComment?.event == "token" && afterComment?.data == "{\"text\":\"a\"}",
               "G5: a keepalive before a real frame leaves the payload intact")

        var midParser = SSEParser()
        _ = midParser.feed(line: "data: first")
        let midComment = midParser.feed(line: ": keepalive")
        expect(midComment == nil, "G5: a comment inside a frame is not a field")
        _ = midParser.feed(line: "data: second")
        let joined = midParser.feed(line: "")
        expect(joined?.data == "first\nsecond",
               "G5: a keepalive between data lines does not corrupt the payload")
        // G5 的另一半（空闲阈值必须 > 10s）目前写死在 `HermesAPI`/`GatewayTransport`
        // 的 session 配置里（60s），单元测试拿不到那个字面量，只能在集成/审查层面核。
        // 若要变成门禁，应抽出一个 `SSEIdleTimeout` 常量再断言 > 10。

        // MARK: - G6 attach/detach 是正常路径

        let accepted = TurnReducer.reduce(started.turn, .submitAccepted(runID: "run-9"))
        expect(accepted.effects == [.attachStream(runID: "run-9", lastEventID: nil)],
               "G6: a fresh run attaches without a cursor")
        let withCursor = TurnReducer.reduce(accepted.turn, .streamEvent(id: "s:7"))
        expect(withCursor.turn == Turn.running(running(runID: "run-9", lastEventID: "s:7")),
               "G6: the SSE cursor is the only thing a detach has to remember")
        let detached = TurnReducer.reduce(withCursor.turn, .streamUnavailable)
        expect(detached.turn == withCursor.turn,
               "G6: losing the stream detaches; the run id and cursor survive")
        expect(detached.effects == [.pollStatus(runID: "run-9", afterSeconds: 1)],
               "G6: a detach falls back to status polling instead of asking the user")
        expect(notices(detached.effects).isEmpty,
               "G6: a detach produces no notice — reconnecting is normal")
        expect(!detached.turn.allowsNewMessage,
               "G6: a detach on a live run does not unlock the composer either")

        // 游标从状态里取出来，原样交给下一次 attach —— 这就是「恢复」的全部。
        let savedCursor: String?
        if case .running(let live) = withCursor.turn { savedCursor = live.lastEventID }
        else { savedCursor = nil }
        expect(TurnEffect.attachStream(runID: "run-9", lastEventID: savedCursor) ==
               .attachStream(runID: "run-9", lastEventID: "s:7"),
               "G6: the saved cursor is exactly what a reattach hands back to the server")
        expect(TurnReducer.reduce(settledBeforeUnknown, .streamUnavailable).turn.allowsNewMessage,
               "G6: a detach on a settled run cannot lock the composer")

        // MARK: - G7 503：等待时长是数据，不是写死的策略

        expect(TurnReducer.backoffSeconds(failures: 1) < TurnReducer.backoffSeconds(failures: 4),
               "G7: the fallback ladder backs off instead of hot-looping")
        // 一次传输失败后 attempts == 2，重放延迟按 failures == 1 取档。
        expect(lostResponse.effects ==
               [.replaySubmission(key: "abc", afterSeconds: TurnReducer.backoffSeconds(failures: 1))],
               "G7: the retry delay rides in the effect, so a Retry-After can override it")
        expect(TurnReducer.reduce(Turn.running(running()), .statusAlive).effects ==
               [.pollStatus(runID: "run-1", afterSeconds: 60)],
               "G7: polling carries its wait as data for the same reason")
        let malformed = TurnReducer.reduce(
            started.turn, .submitRejected(.init(kind: .malformedRequest(status: 400), status: 400)))
        expect(malformed.turn == .idle && replayKeys(malformed.effects).isEmpty,
               "G7: 400 invalid_params is not retryable — the POST is abandoned, not replayed")
        // G7 的另一半（真的读 `Retry-After` 头）当前分支里没有实现：
        // `TurnReducer.backoffSeconds` 的注释写着「由引擎覆盖」，但 grep 不到任何
        // Retry-After 解析。这条只能在引擎补上后才有断言可写。

        // MARK: - G8 跨 surface 绑会话：409 permission_denied，且不留 reservation

        let denied = Turn.Sending.Rejection(kind: .permissionDenied, status: 409)
        expect(!sending(rejection: denied).canReplay,
               "G8: an exact retry would answer 409 again, so replay is not attempted")
        let refused = TurnReducer.reduce(started.turn, .submitRejected(denied))
        expect(refused.turn == .idle,
               "G8: no reservation is kept — the turn goes idle instead of holding a dead key")
        expect(refused.turn.submissionKey == nil && replayKeys(refused.effects).isEmpty,
               "G8: nothing remains that could be replayed")
        expect(denied != Turn.Sending.Rejection(kind: .idempotencyKeyConflict, status: 409),
               "G8: the two 409s stay distinguishable even though both are final")
        // 说明：这里只断言「不重试」。提示文案目前复用 `submissionExpiredWithoutAnswer`
        // （`TurnReducer` 对四种 rejection 都用它），语义上不准，但那是 UX 细节，
        // 不是协议偏离，故不作为门禁。

        // MARK: - G9 shutdown_requested_at 只是预告

        let drainAt = Date()
        let draining = TurnReducer.reduce(Turn.running(running()), .shutdownRequested(at: drainAt))
        expect(draining.turn == Turn.running(running(shutdownRequestedAt: drainAt)),
               "G9: the field is recorded and the status stays `running`")
        expect(!draining.turn.allowsNewMessage && !draining.turn.awaitsReplyBackfill,
               "G9: draining changes neither the send decision nor the backfill")
        expect(draining.effects == [.pollStatus(runID: "run-1", afterSeconds: 5)],
               "G9: the client watches for the promised interrupt instead of inventing one")
        expect(notices(draining.effects).isEmpty,
               "G9: draining is not an error, so it is not surfaced as one")
        let drained = TurnReducer.reduce(draining.turn, .statusTerminal(.interrupted, output: nil))
        expect(notices(drained.effects) == [.interruptedByGateway] && drained.turn.allowsNewMessage,
               "G9: the promised interrupt arrives from the server and is then settled")

        // MARK: - 不变量：历史新鲜度从来不是输入

        let freshnessWords = ["history", "stale", "fresh", "sync", "backfill",
                              "cache", "body", "reply", "caughtup"]
        expect(runningLabels.allSatisfy { label in
            let lower = label.lowercased()
            return !freshnessWords.contains { lower.contains($0) }
        }, "invariant: no field on a Run can express `history is behind`")
        expect(sendingLabels.allSatisfy { label in
            let lower = label.lowercased()
            return !freshnessWords.contains { lower.contains($0) }
        }, "invariant: no field on a Sending can express `history is behind`")
        // 唯一的「待补齐」是派生量 awaitsReplyBackfill，它由 terminal 推出、只用于显示：
        // 存在一个「要补正文但可以发」的状态，就证明它没有反过来参与发送判定。
        expect(Turn.running(running(terminal: .completed)).awaitsReplyBackfill &&
               Turn.running(running(terminal: .completed)).allowsNewMessage,
               "invariant: `awaiting backfill` and `may send` are independent")
        expect(Turn.running(running()).awaitsReplyBackfill == false &&
               Turn.running(running()).allowsNewMessage == false,
               "invariant: neither value is a proxy for the other")

        print("PASS officialcontract (\(checks) checks)")
    }
}
