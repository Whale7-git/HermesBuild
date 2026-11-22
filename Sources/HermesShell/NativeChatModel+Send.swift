import Foundation

extension NativeChatModel {
    @discardableResult
    func send(attachments: [ChatAttachmentPayload] = []) async -> Bool {
        let originalDraft = draft
        let typed = originalDraft.trimmingCharacters(in:.whitespacesAndNewlines)
        // 服务端要求 message 非空；只有附件时用明确占位，并在用户气泡里显示真实内容。
        // 来源在这里判定一次：用户真的输入了这几个字，就不能算系统占位。
        let origin: ChatSendOrigin = typed.isEmpty && !attachments.isEmpty ? .systemPlaceholder : .userInput
        let text = typed.isEmpty ? (attachments.isEmpty ? "" : Self.attachmentOnlyText) : typed
        guard !text.isEmpty else { return false }
        // 斜杠命令（`/compress` 等）由服务端 agent 解释，客户端只负责原样转发。
        // 这里识别它，是为了在"发出去了但服务端没反应"时给出可读说明，
        // 而不是让用户以为命令静默失败了。识别失败（普通文本）返回 nil，行为不变。
        let slashCommand = attachments.isEmpty ? ChatSlashCommand.parse(text) : nil
        // 运行中按用户选的语义分流；其余情况走原来的整轮发送。
        if running, canSendWhileRunning {
            return await sendWhileRunning(text: text, attachments: attachments,
                                          composerText: originalDraft, origin: origin,
                                          slashCommand: slashCommand)
        }
        guard canSend else { return false }
        return await submit(text: text, attachments: attachments, composerText: originalDraft,
                            consumeDraft: true, origin: origin, slashCommand: slashCommand)
    }

    /// 运行中发送：steer 注入 / queue 挂起 / interrupt 先停再发。
    /// 任何一条路径失败都必须把草稿还给用户，不能静默吞掉。
    private func sendWhileRunning(text: String, attachments: [ChatAttachmentPayload],
                                 composerText: String, origin: ChatSendOrigin,
                                 slashCommand: ChatSlashCommand.Match? = nil) async -> Bool {
        switch sendMode {
        case .steer:
            // Neither backend has an attachment-bearing steer contract. Keep
            // the uploaded refs in a complete queued turn instead of claiming
            // success after submitting only its text.
            if !attachments.isEmpty {
                return enqueue(text: text, attachments: attachments, composerText: composerText,
                               origin: origin, notice: "带附件的消息已排队，本轮结束后完整发送。")
            }
            return await steer(text: text, composerText: composerText)
        case .queue:
            return enqueue(text: text, attachments: attachments, composerText: composerText,
                           origin: origin, notice: "已排队，这轮回复结束后自动发出。")
        case .interrupt:
            return await interruptThenSend(text: text, attachments: attachments,
                                           composerText: composerText, origin: origin,
                                           slashCommand: slashCommand)
        }
    }

    private func enqueue(text: String, attachments: [ChatAttachmentPayload], composerText: String,
                         origin: ChatSendOrigin, notice: String) -> Bool {
        guard queuedTurns.count < ChatQueuedTurn.maximumCount else {
            error = "队列已满（最多 \(ChatQueuedTurn.maximumCount) 条），本次草稿和附件已保留。"
            return false
        }
        let turn = ChatQueuedTurn(text: text, attachments: attachments,
                                  composerText: composerText, origin: origin,
                                  automaticAfterStreamID: streamID,
                                  historyEnd: confirmedHistoryEnd,
                                  knownIDs: Self.recoveryKnownIDs(in: buffer.messages))
        // Enqueue never overrides an explicit user pause.
        let next = queuedTurns + [turn]
        // Serialization failure must never delete the previously persisted
        // queue. The new turn remains usable in memory and the UI says so.
        if let data = ChatSendQueueCodec.encode(next) {
            queuedTurns = next
            let result = draftStore?.saveQueued(data) ?? .ok
            if !result.succeeded { recordLocalWrite(result, kind: .queue) }
            queueSaveFailed = !result.succeeded
        } else {
            queuedTurns = next
            queueSaveFailed = true
            recordLocalWrite(.failed(.encoding), kind: .queue)
            RuntimeLogRecorder.shared.record(.warning, "send",
                "queued persistence skipped: payload not serializable")
        }
        if draft == composerText { draft = "" }
        self.notice = queueSaveFailed
            ? "已排队，但这台设备暂时无法保存队列；重启 App 会丢失最新一条。"
            : notice
        error = nil
        settledAttachmentPaths = attachments.map(\.path)
        RuntimeLogRecorder.shared.record(.info, "send",
            "queued count=\(queuedTurns.count) chars=\(text.count) attachments=\(attachments.count)")
        return true
    }

    static func queuedSummary(text: String, attachments: [ChatAttachmentPayload]) -> String {
        ChatQueuedTurn(text: text, attachments: attachments, composerText: text,
                       origin: .userInput, automaticAfterStreamID: nil).summary
    }

    /// steer：不打断当前轮，交给服务端在工具边界注入。
    /// 服务端可能拒收（没有活跃 agent、流已结束等），此时降级成排队并明确告知，
    /// 不能假装已经送达。
    func steer(text: String, composerText: String) async -> Bool {
        let generation = revision
        sendingWhileRunning = true
        defer { sendingWhileRunning = false }
        RuntimeLogRecorder.shared.record(.info, "send", "steer start chars=\(text.count)")
        do {
            let fallback = try await api.steerNativeTurn(sessionID: sessionID, text: text)
            guard generation == revision, !suspended, !Task.isCancelled else { return false }
            if let fallback {
                RuntimeLogRecorder.shared.record(.warning, "send",
                    "steer refused fallback=\(fallback) -> queued")
                return enqueue(text: text, attachments: [], composerText: composerText,
                               origin: .userInput, notice: Self.steerFallbackNotice(fallback))
            }
            error = nil
            if draft == composerText { draft = "" }
            // 引导内容不进本地消息列表：它不是一轮独立发言，服务端会把它并进工具结果。
            notice = "已发送引导，本轮回复继续。"
            RuntimeLogRecorder.shared.record(.info, "send", "steer ok")
            return true
        } catch {
            guard generation == revision, !suspended, !Task.isCancelled else { return false }
            if handleAuthenticationFailure(error) { return false }
            // 网络失败：草稿留着，提示重试；不回退成排队（否则用户以为已送达）。
            let failure = error.localizedDescription
            self.error = failure
            notice = "引导结果未确认，草稿已保留；请核对后再决定是否重发。"
            RuntimeLogRecorder.shared.record(.error, "send", "steer fail err=\(failure)")
            return false
        }
    }

    /// interrupt：先确认本轮停下，再把这条作为新消息发出。
    /// 停止失败就不发 —— 否则两条回复会同时在跑。
    private func interruptThenSend(text: String, attachments: [ChatAttachmentPayload],
                                   composerText: String, origin: ChatSendOrigin,
                                   slashCommand: ChatSlashCommand.Match? = nil) async -> Bool {
        RuntimeLogRecorder.shared.record(.info, "send", "interrupt start")
        if streamID != nil { await stop() }
        guard canSend else {
            notice = "当前回复尚未确认结束，这条没有发出；请先核对状态。"
            return false
        }
        return await submit(text: text, attachments: attachments, composerText: composerText,
                            consumeDraft: true, origin: origin, slashCommand: slashCommand)
    }

    /// steer 被拒时把服务端原因翻译成用户能懂的一句话。
    private static func steerFallbackNotice(_ fallback: String) -> String {
        let reason: String
        switch fallback {
        case "not_running": reason = "本轮已经结束"
        case "stream_dead": reason = "回复流已断开"
        case "no_cached_agent": reason = "服务端没有活跃的 agent"
        case "agent_lacks_steer": reason = "服务端版本不支持引导"
        case "gateway_steer_queued": reason = "网关已改为排队处理"
        default: reason = "服务端未受理"
        }
        return "\(reason)，已改为排队，本轮结束后自动发出。"
    }

    /// Dispatch the oldest eligible turn. The rest remain queued; each later
    /// completion can dispatch the next turn in order.
    @discardableResult
    func flushQueuedIfNeeded(completedStreamID: String? = nil) async -> Bool {
        guard !running, !stopping, !suspended, !stopAcknowledged else { return false }
        // Removing a submitting entry is owned by the completion path. It
        // must never be dispatched again from a foreground/load callback.
        switch ChatQueueDispatchPlan.make(
            turns: queuedTurns, completedStreamID: completedStreamID,
            paused: queueAutomaticDispatchPaused, editing: queueEditingTurnID != nil) {
        case .blocked:
            return false
        case .reconcile:
            error = "队列首条消息的发送结果尚未确认。请先重试、跳过或删除，避免重复提交。"
            return false
        case .dispatch:
            guard canSend else { return false }
        }
        guard let queued = queuedTurns.first else { return false }
        // If the same queued turn was already accepted, the completion path
        // removes it and advances the queue. Nothing else to do here.
        if queued.delivery == .submitting && completedStreamID == nil {
            return false
        }
        // Persist the in-flight state before the network request. Removing the
        // turn first loses it if the process dies between this line and POST
        // acceptance. A failure leaves the turn visible as uncertain rather
        // than silently dispatching it a second time after relaunch.
        // Capture the exact pre-POST boundary in the same durable write as the
        // in-flight state. If the process dies at any point after this line,
        // relaunch can prove delivery/absence instead of trusting the tap that
        // asked to retry.
        queuedTurns[0].historyEnd = confirmedHistoryEnd
        queuedTurns[0].knownIDs = Self.recoveryKnownIDs(in: buffer.messages)
        queuedTurns[0].submittedAt = Date().timeIntervalSince1970
        queuedTurns[0].delivery = .submitting
        // Do not send without a durable pre-POST boundary and delivery state.
        guard persistQueue() else {
            if queuedTurns.first?.id == queued.id {
                queuedTurns[0].delivery = .waiting
                queuedTurns[0].submittedAt = nil
            }
            error = "无法安全保存待发送状态，未向服务器提交。请修复本地存储后重试。"
            return false
        }
        // 排队的那条本身可能就是命令：重新解析一次，让它在真正发出时
        // 也能拿到「已提交」提示与收尾兜底。不给 `QueuedSend` 加字段是为了
        // 不改变它的持久化编码（`record` 的键集合是既有契约）。
        let slashCommand = queued.attachments.isEmpty ? ChatSlashCommand.parse(queued.text) : nil
        let result = await submitQueued(text: queued.text, attachments: queued.attachments,
                                        composerText: queued.composerText, origin: queued.origin,
                                        slashCommand: slashCommand)
        if result.accepted {
            if queuedTurns.first?.id == queued.id {
                queuedTurns.removeFirst()
                if !queuedTurns.isEmpty, running, let active = streamID {
                    // Chain the next turn to this new stream so completion of
                    // this reply dispatches exactly one following turn.
                    queuedTurns[0].automaticAfterStreamID = active
                }
                persistQueue()
            }
        } else if let index = queuedTurns.firstIndex(where: { $0.id == queued.id }) {
            queuedTurns[index].delivery = .uncertain
            queuedTurns[index].automaticAfterStreamID = nil
            persistQueue()
        }
        return result.accepted
    }

    func removeQueuedTurn(id: String) {
        guard queueEditingTurnID == nil else { return }
        guard let index = queuedTurns.firstIndex(where: { $0.id == id }) else { return }
        guard queuedTurns[index].delivery != .submitting else { return }
        queuedTurns.remove(at: index)
        persistQueue()
    }

    /// Explicit recovery for a queue turn whose POST result was lost. The
    /// caller has confirmed that the server has no accepted copy.
    private func retryQueuedTurn(id: String) -> Bool {
        guard queuedTurns.first?.id == id,
              queuedTurns.first?.delivery != .submitting,
              let index = queuedTurns.firstIndex(where: { $0.id == id }) else { return false }
        queuedTurns[index].delivery = .waiting
        queuedTurns[index].automaticAfterStreamID = nil
        persistQueue()
        return true
    }

    /// Recover an uncertain queued turn without guessing whether its failed
    /// POST reached the server. In-process failures retain a pending snapshot.
    /// Restored turns use the pre-POST boundary persisted by version 4. Legacy
    /// queue records without evidence stay locked.
    func prepareQueuedTurnForRetry(id: String) async -> Bool {
        guard queueEditingTurnID == nil,
              !running, !submitting, !loading, !syncing, !reconciling,
              queuedTurns.first?.id == id,
              queuedTurns.first?.delivery == .uncertain else { return false }

        if let pending = pendingSend, pending.text == queuedTurns[0].text,
           pending.attachments == queuedTurns[0].attachments {
            switch await reconcilePending() {
            case .delivered:
                guard queuedTurns.first?.id == id else { return false }
                queuedTurns.removeFirst()
                persistQueue()
                error = nil
                notice = "已确认这条消息此前送达；队列记录已清除，不会重复发送。"
                return false
            case .absent:
                discardPending(restoreDraft: false)
            case .failed:
                error = "仍无法确认队列首条消息是否已送达；发送保持锁定，请稍后核对。"
                return false
            }
        } else if pendingSend != nil {
            // The failed bubble belongs to an earlier explicit turn. It cannot
            // prove whether this queued POST reached the server, so keep both
            // records locked until the user resolves the visible pending send.
            error = "还有另一条发送结果待核对；请先处理会话里的待核对消息。"
            return false
        } else {
            guard queuedTurns[0].hasRecoveryEvidence else {
                error = "这条队列来自旧版本，未保存发送前的历史边界，无法安全确认是否已送达。请刷新核对后手动处理。"
                return false
            }
            reconciling = true
            defer { reconciling = false }
            uncertain = true
            do {
                let snapshot = try await api.history(sessionID: sessionID, before: nil)
                try applySnapshot(snapshot, preserveLoadedOlder: true)
                switch queuedTurns[0].resolution(in: snapshot) {
                case .delivered:
                    guard queuedTurns.first?.id == id else { return false }
                    queuedTurns.removeFirst()
                    persistQueue()
                    uncertain = false
                    error = nil
                    notice = "已确认这条消息此前送达；队列记录已清除，不会重复发送。"
                    return false
                case .absent:
                    break
                case .failed:
                    uncertain = true
                    error = "仍无法确认队列首条消息是否已送达；发送保持锁定，请稍后核对。"
                    return false
                }
            } catch {
                if handleAuthenticationFailure(error) { return false }
                uncertain = true
                self.error = "核对队列消息失败：\(error.localizedDescription)"
                return false
            }
        }

        guard retryQueuedTurn(id: id) else { return false }
        error = nil
        notice = "已确认后台没有这条消息，现在可以重试发送。"
        return true
    }

    /// A normal history refresh can prove a failed queued POST was accepted.
    /// Remove its durable queue record at the same moment the local pending
    /// bubble is settled, so a later "retry" cannot replay the same turn.
    func acknowledgeDeliveredQueuedTurn(matching pending: PendingSend) {
        guard let first = queuedTurns.first,
              first.delivery == .uncertain,
              first.text == pending.text,
              first.attachments == pending.attachments else { return }
        queuedTurns.removeFirst()
        persistQueue()
    }

    func beginQueuedTurnEdit(id: String) -> ChatQueuedTurn? {
        guard queueEditingTurnID == nil,
              let turn = queuedTurns.first(where: { $0.id == id && $0.isWaiting })
        else { return nil }
        queueEditingTurnID = id
        return turn
    }

    func cancelQueuedTurnEdit(id: String) {
        guard queueEditingTurnID == id else { return }
        queueEditingTurnID = nil
    }

    func commitQueuedTurnEdit(id: String, composerText: String) -> Bool {
        guard queueEditingTurnID == id,
              let index = queuedTurns.firstIndex(where: { $0.id == id }),
              let edited = queuedTurns[index].edited(
                  composerText: composerText, attachmentOnlyText: Self.attachmentOnlyText)
        else { return false }
        var next = queuedTurns
        next[index] = edited
        // Do not replace the old row until the edited queue has persisted.
        guard let data = ChatSendQueueCodec.encode(next) else {
            recordLocalWrite(.failed(.encoding), kind: .queue)
            return false
        }
        let result = draftStore?.saveQueued(data) ?? .ok
        guard result.succeeded else {
            recordLocalWrite(result, kind: .queue)
            return false
        }
        queuedTurns = next
        queueSaveFailed = false
        queueEditingTurnID = nil
        return true
    }

    func updateQueuedTurn(id: String, text: String) -> Bool {
        guard queueEditingTurnID == nil else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = queuedTurns.firstIndex(where: { $0.id == id }) else {
            return false
        }
        guard queuedTurns[index].delivery != .submitting else { return false }
        // Editing a turn whose POST may already have reached the server would
        // bypass the recovery evidence: the edited text can no longer match the
        // delivered row. Require explicit reconcile/discard first.
        guard queuedTurns[index].delivery != .uncertain else {
            error = "这条消息的发送结果尚未核对，确认已送达或确认不存在后才能编辑。"
            return false
        }
        var next = queuedTurns
        next[index].text = trimmed
        next[index].composerText = trimmed
        next[index].origin = .userInput
        next[index].delivery = .waiting
        next[index].automaticAfterStreamID = nil
        next[index].historyEnd = nil
        next[index].knownIDs = []
        next[index].submittedAt = nil
        queuedTurns = next
        persistQueue()
        return true
    }

    /// Recovery only inspects user rows newer than the saved boundary, so IDs
    /// already at or below that boundary are redundant. Keep a bounded recent
    /// suffix so one durable queue record never grows with the whole transcript.
    private static func recoveryKnownIDs(in messages: [ChatMessage]) -> Set<String> {
        let recent = messages.suffix(ChatQueuedTurn.maximumKnownIDs)
        return Set(recent.map(\.id))
    }

    func moveQueuedTurn(id: String, before targetID: String) {
        guard queueEditingTurnID == nil, id != targetID,
              let source = queuedTurns.firstIndex(where: { $0.id == id }),
              let target = queuedTurns.firstIndex(where: { $0.id == targetID }) else { return }
        var next = queuedTurns
        let turn = next.remove(at: source)
        let insertion = source < target ? target - 1 : target
        next.insert(turn, at: insertion)
        queuedTurns = next
        persistQueue()
    }

    func setQueuedTurns(_ turns: [ChatQueuedTurn]) {
        guard queueEditingTurnID == nil else { return }
        guard turns.count <= ChatQueuedTurn.maximumCount,
              Set(turns.map(\.id)).count == turns.count,
              !turns.contains(where: { $0.delivery == .submitting }) else { return }
        // P0：已经在途的记录不能被任何批量操作抹掉。
        //
        // 上面的守卫只看**新数组**里有没有 `.submitting`，空数组必然通过，
        // 于是「清空全部排队消息」会把正在 POST 的那条一起删掉。那条记录的
        // `historyEnd` / `knownIDs` 是重启后核对「到底发出去没有」的唯一证据：
        // 删了之后只剩两种坏选择——当没发（可能重复执行）或永久卡住。
        let inFlight = Set(queuedTurns.filter { $0.delivery == .submitting }.map(\.id))
        guard inFlight.isSubset(of: Set(turns.map(\.id))) else {
            queueClearRefusal = "有 \(inFlight.count) 条消息正在发送，无法清除；请等结果出来再试。"
            return
        }
        queueClearRefusal = nil
        queuedTurns = ChatQueueOrdering.prioritize(turns)
        persistQueue()
    }

    func setQueueAutomaticDispatchPaused(_ paused: Bool) {
        // Persist intent before enabling automatic POST dispatch. A failed
        // write must fail closed, not forget the user's pause on restart.
        let saved = draftStore?.saveQueueUserPaused(paused) ?? .ok
        guard saved.succeeded else {
            recordLocalWrite(saved, kind: .queue)
            pauseQueueForRecovery()
            notice = "无法可靠保存队列暂停设置；已保持自动发送锁定。"
            return
        }
        queueUserPaused = paused
        if !paused && !uncertain && activeTurnRecovery == nil {
            queueRecoveryPaused = false
        }
        updateQueuePause()
        if !queueAutomaticDispatchPaused {
            if running, let active = streamID, !queuedTurns.isEmpty {
                // A restored queue has no stream gate. Once the user enables
                // automatic dispatch during the active reply, bind the next
                // turn to that exact stream so it runs only after completion.
                if queuedTurns[0].automaticAfterStreamID == nil {
                    queuedTurns[0].automaticAfterStreamID = active
                    persistQueue()
                }
            } else if !running, !queuedTurns.isEmpty {
                // Enabling the switch is explicit user intent. Dispatch the
                // first ready turn now; later turns remain stream-gated.
                Task { [weak self] in
                    guard let self, !Task.isCancelled else { return }
                    await self.flushQueuedIfNeeded()
                }
            }
        }
        RuntimeLogRecorder.shared.record(.info, "send",
            paused ? "queue auto-dispatch paused" : "queue auto-dispatch resumed")
    }

    func markQueuedTurnForManualDispatch(id: String) {
        guard queueEditingTurnID == nil else { return }
        guard let index = queuedTurns.firstIndex(where: { $0.id == id }) else { return }
        guard queuedTurns[index].delivery == .waiting else { return }
        queuedTurns[index].automaticAfterStreamID = nil
        persistQueue()
    }

    @discardableResult
    private func persistQueue() -> Bool {
        guard let data = ChatSendQueueCodec.encode(queuedTurns) else {
            queueSaveFailed = true
            recordLocalWrite(.failed(.encoding), kind: .queue)
            RuntimeLogRecorder.shared.record(.warning, "send", "queue update persistence failed")
            return false
        }
        let result = draftStore?.saveQueued(queuedTurns.isEmpty ? nil : data) ?? .ok
        queueSaveFailed = !result.succeeded
        // Routine queue mutations do not prove that an earlier failed write was
        // explicitly retried. Only the recovery center clears that sticky issue
        // after its own successful read-back.
        if !result.succeeded { recordLocalWrite(result, kind: .queue) }
        return result.succeeded
    }

    /// Re-run the same verified persistence path without changing queue order,
    /// text, attachment references or delivery state.
    @discardableResult
    func retryQueuePersistence() -> LocalStoreWriteResult {
        let pendingResult = persistPendingSend()
        guard pendingResult.succeeded else { return pendingResult }
        guard let data = ChatSendQueueCodec.encode(queuedTurns) else {
            queueSaveFailed = true
            recordLocalWrite(.failed(.encoding), kind: .queue)
            return .failed(.encoding)
        }
        let result = draftStore?.saveQueued(queuedTurns.isEmpty ? nil : data) ?? .ok
        if !result.succeeded {
            queueSaveFailed = true
            recordLocalWrite(result, kind: .queue)
        }
        return result
    }

    private struct SubmitResult {
        let accepted: Bool
        let completed: Bool
    }

    func submit(text: String, attachments: [ChatAttachmentPayload],
                composerText: String, consumeDraft: Bool,
                origin: ChatSendOrigin,
                slashCommand: ChatSlashCommand.Match? = nil) async -> Bool {
        await performSubmit(text: text, attachments: attachments, composerText: composerText,
                            consumeDraft: consumeDraft, origin: origin,
                            slashCommand: slashCommand).completed
    }

    /// A queued dispatch removes its durable record only after this method
    /// reports an accepted POST. Keeping acceptance separate from the legacy
    /// Boolean result avoids turning an ambiguous transport error into success.
    private func submitQueued(text: String, attachments: [ChatAttachmentPayload],
                              composerText: String, origin: ChatSendOrigin,
                              slashCommand: ChatSlashCommand.Match?) async -> SubmitResult {
        await performSubmit(text: text, attachments: attachments, composerText: composerText,
                            consumeDraft: false, origin: origin,
                            slashCommand: slashCommand)
    }

    private func performSubmit(text: String, attachments: [ChatAttachmentPayload],
                               composerText: String, consumeDraft: Bool,
                               origin: ChatSendOrigin,
                               slashCommand: ChatSlashCommand.Match?) async -> SubmitResult {
        let originalDraft: String? = consumeDraft ? draft : nil
        publishTask?.cancel()
        publishTask = nil
        revision &+= 1
        let generation = revision
        let startedAt = Date().timeIntervalSince1970
        // POST 在途 + 本轮已开始：`.submitting` 同时表达这两件事，
        // 这正是「18 个布尔能组合出非法状态」的典型例子。
        transition(to: .submitting)
        error = nil
        // 斜杠命令：立刻给出「已提交，等待服务端处理」的可见反馈。
        //
        // 之前命令被当成普通消息静默发出去，用户看到气泡却没有任何状态说明，
        // 无法区分「服务端正在处理」与「服务端根本不认这条命令」。
        // 这里只声明「已提交」——压缩是否真的发生只有服务端知道，
        // 写成「正在压缩」会在服务端不支持时骗人。
        notice = slashCommand.flatMap(ChatSlashCommand.submissionNotice(for:))
        // 记下本轮是命令：收尾时若无可见回应，用它补一句说明。
        pendingSlashCommand = slashCommand
        lastEventID = nil
        // 先挂本地气泡再发 POST：网络往返期间用户就能看到自己发出的内容，
        // 并在失败时凭同一行切换成「结果待核对」。
        // 新建 ChatTranscript 保持原有「新回合从干净累加器开始」的语义
        // （terminal/seenEventIDs 必须归零，否则新流的帧会被 terminal 吞掉）。
        let pendingID = "local-" + UUID().uuidString
        // 记下这次 POST 的完整快照：失败后视图才有东西可核对、可重发、可放弃。
        settledAttachmentPaths = []
        let knownIDs = Set(buffer.messages.map(\.id))
        // A disconnected stream may be declared finished only if a new user
        // row AND an assistant answer appear after this immutable boundary.
        activeTurnHistoryBoundary = confirmedHistoryEnd
        pendingSend = PendingSend(id:pendingID, text:text, attachments:attachments,
                                  composerText:composerText, historyEnd:confirmedHistoryEnd,
                                  knownIDs:knownIDs, createdAt:startedAt, origin:origin)
        guard persistPendingSend().succeeded else {
            transition(to: .idle)
            uncertain = true
            error = "发送快照未能安全保存，本次尚未提交。请检查本地存储后重试。"
            return SubmitResult(accepted: false, completed: false)
        }
        // 只有系统补的占位才标记：用户手打同样文字时 origin 是 .userInput，不产生记录。
        if origin == .systemPlaceholder {
            ChatAttachmentPlaceholderStore.shared.rememberLocal(
                scope: displayScope, sessionID: sessionID, id: pendingID)
            placeholderCandidates.append(PlaceholderCandidate(
                localID: pendingID, historyEnd: confirmedHistoryEnd, knownIDs: knownIDs,
                text: text, attachmentPaths: Set(attachments.map(\.path))))
            if placeholderCandidates.count > 8 {
                placeholderCandidates.removeFirst(placeholderCandidates.count - 8)
            }
        }
        pendingAbsent = false
        var turn = ChatTranscript()
        turn.messages = buffer.messages + [ChatMessage(id:pendingID,role:"user",content:text,
                                                       timestamp:startedAt,sourceIndex:nil,
                                                       attachmentPaths:attachments.map(\.path),
                                                       delivery:.submitting)]
        turn.tools = buffer.tools
        buffer = turn
        flush()
        // 关键：**不在 POST 前清 draft**。draft 的 didSet 会落盘到 draftStore，
        // 进程若在发送中被杀，重启后仍能从 draftStore 恢复正文；只有 POST
        // 成功受理后才清（见下方两处 originalDraft 分支）。
        RuntimeLogRecorder.shared.record(.info, "send",
            "post start chars=\(text.count) attachments=\(attachments.count) origin=\(origin == .systemPlaceholder ? "placeholder" : "input")")
        do {
            let active = try await api.startNativeTurn(sessionID:sessionID, text:text,
                attachments:attachments,
                reasoningEffort:api.supportsReasoningEffort ? requestedReasoningEffort : nil)
            // A non-cooperative HTTP completion can arrive after a different
            // session/authentication phase has taken ownership. Never publish
            // its bubble, draft, stream ID or terminal phase into that newer UI.
            // Return not-accepted to the queue owner: it must retain an
            // uncertain durable row, even when the old server accepted POST.
            // Manual sends keep their pre-POST PendingSend for GET-only review.
            if generation != revision &&
               (phase != .submitting || pendingSend?.id != pendingID) {
                RuntimeLogRecorder.shared.record(.warning, "send",
                    "retired POST success retained for read-only reconciliation")
                return SubmitResult(accepted: false, completed: true)
            }
            noteRunRecoveryState()
            RuntimeLogRecorder.shared.record(.info, "send", "post ok stream=\(active)")
            // Persist a separate accepted-run receipt before discarding the
            // original PendingSend. A crash between these writes is safe:
            // at least one durable record still requires GET reconciliation.
            let acceptedRecoverySaved = rememberAcceptedTurn(
                runID: active, text: text, attachments: attachments,
                knownIDs: knownIDs)
            if let originalDraft, draft == originalDraft { draft = "" }
            setDelivery(.accepted, for: pendingID)
            // Keep the original PendingSend when persisting its replacement
            // failed: this POST was accepted, so an automatic retry is unsafe.
            if acceptedRecoverySaved {
                pendingSend = nil
            } else {
                uncertain = true
                pauseQueueForRecovery()
                notice = "后台已受理消息，但本地运行记录写入失败；请勿重发，稍后核对。"
            }
            settledAttachmentPaths = attachments.map(\.path)
            pendingAbsent = false
            flush()
            streamID = active

            guard generation == revision else {
                transition(to: .idle)
                // Session was switched while POST was in flight. Only
                // reconcile its result; do not attach an old stream to a new UI.
                resumeRequested = false
                await load(silent: true, preserveLoadedOlder: true)
                return SubmitResult(accepted: true, completed: true)
            }
            resumeRequested = false
            transition(to: .streaming(connected: false))
            attach(streamID: active)
            return SubmitResult(accepted: true, completed: true)
        } catch {
            // POST 失败时页面可能已经切走/刷新：失配就只做本地收尾，
            // 不把旧请求的 error/draft/notice 写回新会话的状态。
            guard generation == revision else {
                // A different phase or submission must never be reset by an
                // old failure. The durable pending record stays fail-closed.
                if phase == .submitting && pendingSend?.id == pendingID {
                    transition(to: .idle)
                }
                return SubmitResult(accepted: false, completed: true)
            }
            self.error = error.localizedDescription
            RuntimeLogRecorder.shared.record(.error, "send", "post fail err=\(error.localizedDescription)")
            // POST 结果不明：退回静止态，用 uncertain 锁住发送。
            // 不保留 `.submitting`——那会让界面永远停在「正在发送…」。
            transition(to: .idle)
            uncertain = true
            setDelivery(.unconfirmed, for:pendingID)
            flush()
            // 供用户直接重发：不覆盖等待期间新输入的内容。
            if draft.isEmpty, let originalDraft { draft = originalDraft }
            if handleAuthenticationFailure(error) {
                return SubmitResult(accepted: false, completed: true)
            }
            notice = "发送结果未确认，请先核对状态；草稿和附件已保留。"
            if resumeRequested { resumeRequested = false; await load(silent: true, preserveLoadedOlder: true) }
        }
        return SubmitResult(accepted: false, completed: true)
    }

    /// 最后一条尚未确认送达的本地用户气泡 id；视图据此显示三态并提供核对入口。
    /// 读 buffer 而不是 transcript，避免 40ms 发布节流造成短暂的不同步。
    func pendingUserMessageID() -> String? {
        buffer.messages.last(where: { $0.delivery != .confirmed })?.id
    }

    /// 核对成功后丢弃本地占位气泡；只影响内存里的本地行，不触碰服务端历史。
    func discardPendingMessage(id: String) {
        guard let index = buffer.messages.firstIndex(where: { $0.id == id }) else { return }
        ChatAttachmentPlaceholderStore.shared.forgetLocal(
            scope: displayScope, sessionID: sessionID, id: id)
        buffer.messages.remove(at: index)
        flush()
    }

    /// A GET refresh settles against this POST's original history boundary and
    /// attachment refs. It never sends a POST and never matches an older echo.
    func reconcilePending() async -> PendingReconcileResult {
        guard let pending = pendingSend else { return .failed }
        guard !loading, !syncing, !reconciling, !submitting else { return .failed }
        // 核对期间必须置位：视图的 pendingBusy 读它来禁用「核对/重发/放弃」。
        // silent 刷新不会设 loading，不置这个标志时三个按钮看起来都可用，
        // 连点会并发发起多个 GET。
        // 核对不是相位，而是与相位正交的事实：这次 GET 自己会走 `.syncing`，
        // 「核对中」与「同步中」必须同时成立。
        reconciling = true
        defer { reconciling = false }
        pendingAbsent = false
        uncertain = true
        // A-07：这个 GET 归核对流程所有，必须允许在 reconciling 置位期间执行，
        // 且不能再让 refresh() 把标志抹掉（resetReconciling: false）。
        await refresh(silent: true, preserveLoadedOlder: true, resetReconciling: false)
        guard !Task.isCancelled, error == nil else { return .failed }
        if pendingSend == nil { return .delivered }
        guard pendingSend?.id == pending.id else { return .failed }
        if pendingAbsent { return .absent }

        // If the latest page does not cover the pre-POST boundary, read back
        // through contiguous raw history indexes. These GETs never send a turn.
        guard let historyEnd = pending.historyEnd,
              let latest = latestRecoverySnapshot,
              latest.sessionID == sessionID, !latest.readOnly,
              latest.activeRunEvidence == .absent,
              latest.olderOffset > historyEnd else { return .failed }
        let generation = revision
        var pages = [latest]
        for _ in 0..<63 where (pages.last?.olderOffset ?? 0) > historyEnd {
            guard !Task.isCancelled, generation == revision,
                  pendingSend?.id == pending.id, !suspended else { return .failed }
            let cursor = pages[pages.count - 1].olderOffset
            do {
                let older = try await api.history(sessionID: sessionID, before: cursor)
                guard generation == revision, pendingSend?.id == pending.id,
                      !Task.isCancelled, !suspended,
                      older.sessionID == sessionID, !older.readOnly,
                      older.activeRunEvidence == .absent,
                      older.rawMessageEndIndex == cursor,
                      older.olderOffset < cursor else { return .failed }
                pages.append(older)
            } catch {
                if handleAuthenticationFailure(error) { return .failed }
                notice = "历史分页核对暂不可用；已保留发送记录，不会自动重发。"
                return .failed
            }
        }
        guard (pages.last?.olderOffset ?? Int.max) <= historyEnd else { return .failed }
        let decision = DeliveryReconciliationPolicy.resolve(
            text: pending.text, attachments: pending.attachments,
            historyEnd: historyEnd, knownIDs: pending.knownIDs, pages: pages)
        guard decision != .failed else { return .failed }
        do {
            let current = try await api.history(sessionID: sessionID, before: nil)
            guard generation == revision, pendingSend?.id == pending.id,
                  !Task.isCancelled, !suspended,
                  current.sessionID == sessionID, !current.readOnly,
                  current.activeRunEvidence == .absent,
                  current.rawMessageEndIndex == latest.rawMessageEndIndex,
                  current.messages.last?.id == latest.messages.last?.id else { return .failed }
        } catch {
            if handleAuthenticationFailure(error) { return .failed }
            return .failed
        }
        if decision == .delivered {
            buffer.messages.removeAll { $0.id == pending.id }
            pendingSend = nil
            acknowledgeDeliveredQueuedTurn(matching: pending)
            if draft == pending.composerText { draft = "" }
            notice = "已从完整历史确认消息送达；没有重新提交。"
            uncertain = false
            pendingAbsent = false
        } else {
            // A proven absence enables only explicit user choice, never POST.
            pendingAbsent = true
            uncertain = false
            notice = "完整历史核对未发现这条消息，可自行决定是否重发。"
        }
        flush()
        return decision
    }

    /// 仅在核对确认后台不存在（`.absent`）后重发，附件原样带回（服务端引用，不重新上传）。
    func resendPending() async -> Bool {
        guard canResendPending, let pending = pendingSend else { return false }
        buffer.messages.removeAll { $0.id == pending.id }
        uncertain = false
        pendingAbsent = false
        pendingSend = nil
        // A new draft typed while the first POST waited belongs to the next
        // turn. Retrying the original payload must not overwrite or send it.
        let consumeDraft = draft == pending.composerText
        // 旧气泡已经移除，对应的临时标记一并作废；重发沿用同一来源判定。
        ChatAttachmentPlaceholderStore.shared.forgetLocal(
            scope: displayScope, sessionID: sessionID, id: pending.id)
        flush()
        return await submit(text: pending.text, attachments: pending.attachments,
                            composerText: pending.composerText, consumeDraft: consumeDraft,
                            origin: pending.origin)
    }

    /// 放弃这条待核对消息：只清本地占位与待核对状态，不触碰服务端历史。
    func discardPending(restoreDraft: Bool = true) {
        // 提交中不收尾：此时 pendingSend 已是新一次发送的快照。
        guard !submitting, !loading, !syncing, !reconciling, let pending = pendingSend else { return }
        ChatAttachmentPlaceholderStore.shared.forgetLocal(
            scope: displayScope, sessionID: sessionID, id: pending.id)
        buffer.messages.removeAll { $0.id == pending.id }
        let stillUncertain = !pendingAbsent
        uncertain = stillUncertain
        pendingAbsent = false
        if stillUncertain {
            var retained = pending
            retained.hiddenFromTranscript = true
            pendingSend = retained
        } else {
            pendingSend = nil
        }
        // 原文回填只填空输入框，不覆盖等待期间的新输入；附件占位不是用户文本。
        if restoreDraft,
           draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !pending.composerText.isEmpty {
            draft = pending.composerText
        }
        notice = stillUncertain ? "已移除本地占位；后台状态仍待核对，请刷新历史后再发送。" : nil
        flush()
    }

    private func setDelivery(_ delivery: ChatDeliveryState, for id: String) {
        guard let index = buffer.messages.firstIndex(where: { $0.id == id }) else { return }
        buffer.messages[index].delivery = delivery
    }

}
