import Foundation

extension NativeChatModel {
    @discardableResult
    func send(attachments: [ChatAttachmentPayload] = []) async -> Bool {
        guard !draftRecoveryUnreadable else { return false }
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
            recordRuntimeLog(.warning, "send",
                "queued persistence skipped: payload not serializable")
        }
        clearOriginalDraft(composerText)
        self.notice = queueSaveFailed
            ? "已排队，但这台设备暂时无法保存队列；重启 App 会丢失最新一条。"
            : notice
        error = nil
        settledAttachmentPaths = attachments.map(\.path)
        recordRuntimeLog(.info, "send",
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
        recordRuntimeLog(.info, "send", "steer start chars=\(text.count)")
        do {
            let fallback = try await api.steerNativeTurn(sessionID: sessionID, text: text)
            guard generation == revision, !suspended, !Task.isCancelled else { return false }
            if let fallback {
                recordRuntimeLog(.warning, "send",
                    "steer refused fallback=\(fallback) -> queued")
                return enqueue(text: text, attachments: [], composerText: composerText,
                               origin: .userInput, notice: Self.steerFallbackNotice(fallback))
            }
            error = nil
            clearOriginalDraft(composerText)
            // 引导内容不进本地消息列表：它不是一轮独立发言，服务端会把它并进工具结果。
            notice = "已发送引导，本轮回复继续。"
            recordRuntimeLog(.info, "send", "steer ok")
            return true
        } catch {
            guard generation == revision, !suspended, !Task.isCancelled else { return false }
            if handleAuthenticationFailure(error) { return false }
            // 网络失败：草稿留着，提示重试；不回退成排队（否则用户以为已送达）。
            let failure = error.localizedDescription
            self.error = failure
            notice = "暂时无法确认补充消息是否送达，已保留草稿。"
            recordRuntimeLog(.error, "send", "steer fail err=\(failure)")
            return false
        }
    }

    /// interrupt：先确认本轮停下，再把这条作为新消息发出。
    /// 停止失败就不发 —— 否则两条回复会同时在跑。
    private func interruptThenSend(text: String, attachments: [ChatAttachmentPayload],
                                   composerText: String, origin: ChatSendOrigin,
                                   slashCommand: ChatSlashCommand.Match? = nil) async -> Bool {
        recordRuntimeLog(.info, "send", "interrupt start")
        if streamID != nil { await stop() }
        guard canSend else {
            notice = "上一条回复尚未确认结束，这条消息未发送，请同步状态。"
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
        default: reason = "服务端未接收消息"
        }
        return "\(reason)，已改为排队，本轮结束后自动发出。"
    }

    /// Dispatch the oldest eligible turn. The rest remain queued; each later
    /// completion can dispatch the next turn in order.
    @discardableResult
    func flushQueuedIfNeeded(completedStreamID: String? = nil, expectedTurnID: String? = nil) async -> Bool {
        guard !runtimeRetired, !recoveryOnly, !running, !stopping, !suspended, !stopAcknowledged,
              expectedTurnID == nil || queuedTurns.first?.id == expectedTurnID else { return false }
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
        var submittingQueue = queuedTurns
        submittingQueue[0].historyEnd = confirmedHistoryEnd
        submittingQueue[0].knownIDs = Self.recoveryKnownIDs(in: buffer.messages)
        submittingQueue[0].submittedAt = Date().timeIntervalSince1970
        submittingQueue[0].submissionKey = api.carriesRunSubmissionIdentity ? RunSubmissionIdentity.make() : nil
        submittingQueue[0].delivery = .submitting
        // Do not send without a durable pre-POST boundary and delivery state.
        guard commitQueueMutation(submittingQueue) else {
            error = "无法安全保存待发送状态，未向服务器提交。请修复本地存储后重试。"
            return false
        }
        // 排队的那条本身可能就是命令：重新解析一次，让它在真正发出时
        // 也能拿到「已提交」提示与收尾兜底。不给 `QueuedSend` 加字段是为了
        // 不改变它的持久化编码（`record` 的键集合是既有契约）。
        let slashCommand = queued.attachments.isEmpty ? ChatSlashCommand.parse(queued.text) : nil
        let result = await submitQueued(text: queued.text, attachments: queued.attachments,
                                        composerText: queued.composerText, origin: queued.origin,
                                        slashCommand: slashCommand, queuedTurnID: queued.id)
        guard !runtimeRetired else { return false }
        if result.accepted {
            // The exact accepted receipt owns removal. If its persistence
            // failed, retain the original queued and pending evidence.
            if activeTurnRecovery?.queuedTurnID == queued.id {
                if let receipt = activeTurnRecovery, !settleAcceptedReceipt(receipt) {
                    // 已受理，但本地结算没写进去。这不是「投递未知」，绝不能落成
                    // `.none`/`.absent`——那条队列行还在，重发就是对已在跑的 run
                    // 再 POST 一次。
                    gate.pending = .acceptedUnretired
                    syncUncertain()
                    pauseQueueForRecovery()
                }
            }
            if let index = queuedTurns.firstIndex(where: { $0.id == queued.id }) {
                queuedTurns[index].delivery = .uncertain
                // 服务端已受理（result.accepted），这一行只是删不掉。置回 `.waiting`
                // 会让 `ChatQueueDispatchPlan` 直接再 dispatch 同一条消息。
                gate.pending = .acceptedUnretired
                syncUncertain()
                queuedTurns[index].automaticAfterStreamID = nil
                persistQueue()
                pauseQueueForRecovery()
            }
        } else if let index = queuedTurns.firstIndex(where: { $0.id == queued.id }) {
            queuedTurns[index].delivery = .uncertain
            queuedTurns[index].automaticAfterStreamID = nil
            persistQueue()
        }
        return result.accepted
    }

    func removeQueuedTurn(id: String) {
        guard queueEditingTurnID == nil, !reconciling else { return }
        guard let index = queuedTurns.firstIndex(where: { $0.id == id }) else { return }
        guard queuedTurns[index].delivery != .submitting else { return }
        var next = queuedTurns
        next.remove(at: index)
        commitQueueMutation(next)
    }

    /// Explicit recovery for a queue turn whose POST result was lost. The
    /// caller has confirmed that the server has no accepted copy.
    private func retryQueuedTurn(id: String) -> Bool {
        guard queuedTurns.first?.id == id,
              queuedTurns.first?.delivery != .submitting,
              let index = queuedTurns.firstIndex(where: { $0.id == id }) else { return false }
        var next = queuedTurns
        next[index].delivery = .waiting
        next[index].automaticAfterStreamID = nil
        next[index].submissionKey = nil
        return commitQueueMutation(next)
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

        restoreKeyedQueuedPendingIfNeeded()
        if let pending = pendingSend, pending.queuedTurnID == id {
            switch await reconcilePending() {
            case .delivered:
                // The common history settlement owns durable removal.
                return false
            case .absent:
                discardPending(restoreDraft: false)
                guard pendingSend == nil else { return false }
            case .failed:
                error = pendingDeliveryIsVerified ? "消息已送达，仍需确认任务是否结束。请在恢复中心处理。"
                    : "仍无法确认队列首条消息是否送达，暂不能发送，请稍后同步。"
                return false
            }
        } else if pendingSend != nil {
            // The failed bubble belongs to an earlier explicit turn. It cannot
            // prove whether this queued POST reached the server, so keep both
            // records locked until the user resolves the visible pending send.
            error = "还有一条消息尚未确认送达，请先处理那条消息。"
            return false
        } else {
            let original = queuedTurns[0]
            guard original.hasRecoveryEvidence, let historyEnd = original.historyEnd else {
                error = "这条消息来自旧版本，暂时无法确认是否送达，请同步后再决定如何处理。"
                return false
            }
            reconciling = true
            // 核对窗口内必须继续挡发送：这是 GET 在途（可能是多次 await、数秒），
            // 放行会让用户或自动 flush 把同一条 uncertain 队列消息再 POST 一次。
            gate.pending = .reconciling
            syncUncertain()
            // 但窗口一关就必须结清：`applySnapshot` 刻意绕过 `.reconciling`
            // 不动它（那是并发发送的闸），所以任何提前 return 都得在这里收尾，
            // 否则它会永久挡住发送。
            defer {
                reconciling = false
                if gate.pending == .reconciling {
                    gate.pending = .none
                    syncUncertain()
                }
            }
            let generation = revision
            func stillOwnsProof() -> Bool {
                generation == revision && !runtimeRetired && !suspended && !Task.isCancelled
                    && queuedTurns.first == original && pendingSend == nil
            }
            do {
                let snapshot = try await recoveryHistory(sessionID: sessionID, before: nil)
                guard stillOwnsProof() else { return false }
                guard snapshot.sessionID == sessionID,
                      !snapshot.readOnly, snapshot.activeRunEvidence == .absent else {
                    error = "暂时无法确认上一条消息是否已结束。队列已保留，不会重复发送。"
                    return false
                }
                var pages = [snapshot]
                for _ in 0..<63 where (pages.last?.olderOffset ?? 0) > historyEnd {
                    guard stillOwnsProof(), let cursor = pages.last?.olderOffset else { return false }
                    let older = try await recoveryHistory(sessionID: sessionID, before: cursor)
                    guard stillOwnsProof() else { return false }
                    guard older.sessionID == sessionID, !older.readOnly,
                          older.activeRunEvidence == .absent,
                          older.rawMessageEndIndex == cursor, older.olderOffset < cursor else {
                        error = "较早的消息暂时无法完整读取，原消息仍保留，请稍后重试。"
                        return false
                    }
                    pages.append(older)
                }
                let decision = original.resolution(in: pages)
                guard decision != .failed else {
                    error = "历史证据不足，已保留队列记录；不会自动重发。"
                    return false
                }
                if pages.count > 1 {
                    let head = try await recoveryHistory(sessionID: sessionID, before: nil)
                    guard stillOwnsProof() else { return false }
                    guard head.sessionID == sessionID, !head.readOnly,
                          head.activeRunEvidence == .absent,
                          head.rawMessageEndIndex == snapshot.rawMessageEndIndex,
                          head.messages == snapshot.messages else {
                        error = "同步期间消息发生变化，请重新同步后再发送。"
                        return false
                    }
                }
                guard stillOwnsProof() else { return false }
                try applySnapshot(snapshot, preserveLoadedOlder: true)
                guard stillOwnsProof(), activeTurnRecovery == nil else {
                    // 证明权已丢，或还有一份已受理未确认结束的 Run：这个 Run 的死活
                    // 现在确认不了，只能记 `.unknown`（无 id 也要锁）。
                    gate.run = .unknown(runID: activeTurnRecovery?.runID)
                    syncUncertain()
                    return false
                }
                switch decision {
                case .delivered:
                    guard queuedTurns.first?.id == id else { return false }
                    var next = queuedTurns
                    next.removeFirst()
                    guard commitQueueMutation(next) else {
                        // 送达已被历史证实，锁的是「这条队列记录删不掉」；它不是
                        // 「没送到」，所以只能是 acceptedUnretired。
                        gate.pending = .acceptedUnretired
                        syncUncertain()
                        return false
                    }
                    gate.pending = .none
                    syncUncertain()
                    error = nil
                    notice = "已确认这条消息此前送达；队列记录已清除，不会重复发送。"
                    return false
                case .absent:
                    // 完整分页 + 稳定 head 证明服务端没有这条：这一笔待核对事务就此
                    // 结清（随后 `retryQueuedTurn` 会把它排成一条**全新的** POST，
                    // 不是重放旧请求）。不结清的话，`.reconciling` 会一直留在这里。
                    gate.pending = .none
                    syncUncertain()
                case .failed:
                    // 证据不足（分页不连续 / 窗口没覆盖 boundary / keyed 记录），
                    // 投递结果仍未确定：保持锁，绝不当成 proven absent。
                    gate.pending = .awaitingDecision
                    syncUncertain()
                    error = "仍无法确认队列首条消息是否送达，暂不能发送，请稍后同步。"
                    return false
                }
            } catch {
                guard stillOwnsProof() else { return false }
                if handleAuthenticationFailure(error) { return false }
                // 触发源是历史读取失败（D），但这处断言的是「这笔 POST 仍未结算」；
                // 按保守口径留在 pending，历史新鲜度只做记录。
                gate.historyFresh = false
                gate.pending = .awaitingDecision
                syncUncertain()
                self.error = "同步队列消息失败：\(error.localizedDescription)"
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
    @discardableResult
    func acknowledgeDeliveredQueuedTurn(matching pending: PendingSend) -> Bool {
        guard let id = pending.queuedTurnID else { return true }
        guard !queueRecoveryUnreadable else { return false }
        guard let index = queuedTurns.firstIndex(where: { $0.id == id }) else { return true }
        guard queuedTurns[index].needsReconcile,
              queuedTurns[index].submissionKey == pending.submissionKey else { return false }
        var next = queuedTurns
        next.remove(at: index)
        return commitQueueMutation(next)
    }

    /// The accepted receipt survives a failed queue write or process death.
    /// Remove exactly its in-flight row, never a waiting sibling.
    @discardableResult
    func retireAcceptedQueueTurn(id: String, nextRunID: String, submissionKey: String? = nil) -> Bool {
        guard !queueRecoveryUnreadable else { return false }
        guard let index = queuedTurns.firstIndex(where: { $0.id == id }) else { return true }
        guard queuedTurns[index].needsReconcile,
              queuedTurns[index].submissionKey == submissionKey else { return false }
        var next = queuedTurns
        next.remove(at: index)
        if index == 0, !next.isEmpty, next[0].delivery == .waiting {
            next[0].automaticAfterStreamID = nextRunID
        }
        return commitQueueMutation(next)
    }

    /// Publish a queue mutation only after the new complete snapshot is durable.
    /// Enqueue keeps its explicit in-memory fallback; destructive edits do not.
    @discardableResult
    private func commitQueueMutation(_ next: [ChatQueuedTurn]) -> Bool {
        guard !runtimeRetired, !queueRecoveryUnreadable else { return false }
        guard let data = ChatSendQueueCodec.encode(next) else {
            recordLocalWrite(.failed(.encoding), kind: .queue)
            return false
        }
        let result = draftStore?.saveQueued(next.isEmpty ? nil : data) ?? .ok
        guard result.succeeded else {
            recordLocalWrite(result, kind: .queue)
            pauseQueueForRecovery()
            error = "无法保存队列变更，原记录已保留；请检查本地存储。"
            return false
        }
        queuedTurns = next
        queueSaveFailed = false
        return true
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
            error = "这条消息尚未确认是否送达，暂不能编辑。"
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
        next[index].submissionKey = nil
        return commitQueueMutation(next)
    }

    /// Recovery only inspects user rows newer than the saved boundary, so IDs
    /// already at or below that boundary are redundant. Keep a bounded recent
    /// suffix so one durable queue record never grows with the whole transcript.
    private static func recoveryKnownIDs(in messages: [ChatMessage]) -> Set<String> {
        let recent = messages.suffix(ChatQueuedTurn.maximumKnownIDs)
        return Set(recent.map(\.id))
    }

    func moveQueuedTurn(id: String, before targetID: String) {
        guard queueEditingTurnID == nil, !reconciling,
              !queuedTurns.contains(where: { $0.delivery == .submitting }), id != targetID,
              let source = queuedTurns.firstIndex(where: { $0.id == id }),
              let target = queuedTurns.firstIndex(where: { $0.id == targetID }) else { return }
        var next = queuedTurns
        let turn = next.remove(at: source)
        let insertion = source < target ? target - 1 : target
        next.insert(turn, at: insertion)
        commitQueueMutation(ChatQueueOrdering.prioritize(next))
    }

    func setQueuedTurns(_ turns: [ChatQueuedTurn]) {
        guard queueEditingTurnID == nil, !reconciling else { return }
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
        if commitQueueMutation(ChatQueueOrdering.prioritize(turns)) {
            queueClearRefusal = nil
        } else {
            queueClearRefusal = "无法保存队列变更，原记录已保留。"
        }
    }

    func setQueueAutomaticDispatchPaused(_ paused: Bool) {
        guard paused || !recoveryRecordsUnreadable else { return }
        // Persist intent before enabling automatic POST dispatch. A failed
        // write must fail closed, not forget the user's pause on restart.
        let saved = draftStore?.saveQueueUserPaused(paused) ?? .ok
        guard saved.succeeded else {
            // A failed pause write must not let a later network recovery
            // override the user's explicit wish to stop automatic dispatch.
            if paused { queueUserPaused = true }
            recordLocalWrite(saved, record: .queuePause)
            pauseQueueForRecovery()
            notice = "队列暂停设置保存失败，自动发送仍已暂停。"
            return
        }
        queueUserPaused = paused
        recordSuccessfulLocalWrite(record: .queuePause)
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
        recordRuntimeLog(.info, "send",
            paused ? "queue auto-dispatch paused" : "queue auto-dispatch resumed")
    }

    /// Both composer and queue manager must dispatch the exact selected ID.
    /// Stale taps, refused reorder and asynchronous reconciliation never
    /// fall back to a different first item.
    @discardableResult
    func dispatchSelectedQueuedTurn(id: String) async -> Bool {
        guard !runtimeRetired, !reconciling, queueEditingTurnID == nil,
              !running, !submitting, !loading, !syncing, !stopping,
              let selected = queuedTurns.first(where: { $0.id == id }),
              selected.delivery != .submitting else { return false }
        if let first = queuedTurns.first, first.id != id {
            moveQueuedTurn(id: id, before: first.id)
        }
        guard queuedTurns.first?.id == id else { return false }
        if selected.delivery == .uncertain {
            guard await prepareQueuedTurnForRetry(id: id) else { return false }
        } else {
            markQueuedTurnForManualDispatch(id: id)
        }
        return await flushQueuedIfNeeded(expectedTurnID: id)
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
        guard !runtimeRetired, !queueRecoveryUnreadable else { return false }
        guard let data = ChatSendQueueCodec.encode(queuedTurns) else {
            queueSaveFailed = true
            recordLocalWrite(.failed(.encoding), kind: .queue)
            recordRuntimeLog(.warning, "send", "queue update persistence failed")
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
        guard !runtimeRetired, !queueRecoveryUnreadable, !pendingRecoveryUnreadable else {
            return .failed(.corruptFile)
        }
        let pendingResult = persistPendingSend()
        guard pendingResult.succeeded else { return pendingResult }
        guard let data = ChatSendQueueCodec.encode(queuedTurns) else {
            queueSaveFailed = true
            recordLocalWrite(.failed(.encoding), kind: .queue)
            return .failed(.encoding)
        }
        let result = draftStore?.saveQueued(queuedTurns.isEmpty ? nil : data) ?? .ok
        guard result.succeeded else {
            recordLocalWrite(result, record: .queuedTurns)
            return result
        }
        recordSuccessfulLocalWrite(record: .queuedTurns)
        // Retry the actual current pause intent, never enable dispatch as a
        // side effect of fixing persistence. A failed unpause stays paused.
        if localRecordIssues[.queuePause] != nil {
            let saved = draftStore?.saveQueueUserPaused(queueUserPaused) ?? .ok
            guard saved.succeeded else {
                recordLocalWrite(saved, record: .queuePause)
                return saved
            }
            recordSuccessfulLocalWrite(record: .queuePause)
        }
        return .ok
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
                              slashCommand: ChatSlashCommand.Match?, queuedTurnID: String) async -> SubmitResult {
        await performSubmit(text: text, attachments: attachments, composerText: composerText,
                            consumeDraft: false, origin: origin,
                            slashCommand: slashCommand, queuedTurnID: queuedTurnID)
    }

    private func performSubmit(text: String, attachments: [ChatAttachmentPayload],
                               composerText: String, consumeDraft: Bool,
                               origin: ChatSendOrigin,
                               slashCommand: ChatSlashCommand.Match?, queuedTurnID: String? = nil) async -> SubmitResult {
        guard !runtimeRetired, !recoveryOnly else { return SubmitResult(accepted: false, completed: false) }
        let originalDraft: String? = consumeDraft ? draft : nil
        publishTask?.cancel()
        publishTask = nil
        revision &+= 1
        let generation = revision
        let startedAt = Date().timeIntervalSince1970
        // POST 在途 + 本轮已开始：`.submitting` 同时表达这两件事，
        // 这正是「18 个布尔能组合出非法状态」的典型例子。
        transition(to: .submitting)
        lastFinalizedRecord = nil
        if let cleared = draftStore?.saveRunOutcome(nil) {
            if cleared.succeeded { recordSuccessfulLocalWrite(record: .runOutcome) }
            else { recordLocalWrite(cleared, record: .runOutcome) }
        }
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
        let submissionKey: String?
        if api.carriesRunSubmissionIdentity {
            if let queuedTurnID {
                guard let key = queuedTurns.first(where: { $0.id == queuedTurnID })?.submissionKey,
                      RunSubmissionIdentity.valid(key) else {
                    transition(to: .idle)
                    // 什么都没发出去：POST 根本没离开设备。锁必须落在「本地记录
                    // 不完整」上，不能写成「投递未知」（那会诱使按结果未知处理）。
                    gate.store = .degraded(reason: "queue-record-incomplete")
                    syncUncertain()
                    pauseQueueForRecovery()
                    error = "发送记录不完整，本次未发送。"
                    return SubmitResult(accepted: false, completed: false)
                }
                submissionKey = key
            } else { submissionKey = RunSubmissionIdentity.make() }
        } else { submissionKey = nil }
        let effort = api.supportsReasoningEffort ? requestedReasoningEffort : nil
        // 记下这次 POST 的完整快照：失败后视图才有东西可核对、可重发、可放弃。
        settledAttachmentPaths = []
        let knownIDs = Set(buffer.messages.map(\.id))
        // A disconnected stream may be declared finished only if a new user
        // row AND an assistant answer appear after this immutable boundary.
        activeTurnHistoryBoundary = confirmedHistoryEnd
        let pending = PendingSend(id:pendingID, text:text, attachments:attachments,
                                  composerText:composerText, historyEnd:confirmedHistoryEnd,
                                  knownIDs:knownIDs, createdAt:startedAt, origin:origin,
                                  queuedTurnID: queuedTurnID, submissionKey: submissionKey,
                                  reasoningEffort: effort)
        guard preparePendingSubmission(pending).succeeded else {
            transition(to: .idle)
            // 同样没发出：PendingSend 已经在内存里（hasPendingSend 自会挡发送），
            // 这里锁的是「写不进盘」这件事。
            gate.store = .degraded(reason: "pending-save-failed")
            syncUncertain()
            error = "发送记录保存失败，本次未发送。请检查本地存储后重试。"
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
        latestSubmissionFocus = ChatTurnFocusProof(localID: pendingID, historyEnd: confirmedHistoryEnd,
            knownIDs: knownIDs, text: text, attachmentPaths: Set(attachments.map(\.path)))
        buffer = turn
        flush()
        // 关键：**不在 POST 前清 draft**。draft 的 didSet 会落盘到 draftStore，
        // 进程若在发送中被杀，重启后仍能从 draftStore 恢复正文；只有 POST
        // 成功受理后才清（见下方两处 originalDraft 分支）。
        recordRuntimeLog(.info, "send",
            "post start chars=\(text.count) attachments=\(attachments.count) origin=\(origin == .systemPlaceholder ? "placeholder" : "input")")
        do {
            let active = try await api.startNativeTurn(sessionID:sessionID, text:text,
                attachments:attachments,
                reasoningEffort:effort, submissionKey:submissionKey)
            // A non-cooperative HTTP completion can arrive after a different
            // session/authentication phase has taken ownership. Never publish
            // its bubble, draft, stream ID or terminal phase into that newer UI.
            // Return not-accepted to the queue owner: it must retain an
            // uncertain durable row, even when the old server accepted POST.
            // Manual sends keep their pre-POST PendingSend for GET-only review.
            if runtimeRetired || (generation != revision &&
               (phase != .submitting || pendingSend?.id != pendingID)) {
                recordRuntimeLog(.warning, "send",
                    "retired POST success retained for read-only reconciliation")
                return SubmitResult(accepted: false, completed: true)
            }
            noteRunRecoveryState()
            recordRuntimeLog(.info, "send", "post ok stream=\(active)")
            // Persist a separate accepted-run receipt before discarding the
            // original PendingSend. A crash between these writes is safe:
            // at least one durable record still requires GET reconciliation.
            let acceptedRecoverySaved = rememberAcceptedTurn(
                runID: active, text: text, attachments: attachments,
                knownIDs: knownIDs)
            if let originalDraft { clearOriginalDraft(originalDraft) }
            setDelivery(.accepted, for: pendingID)
            // Keep the original PendingSend when persisting its replacement
            // failed: this POST was accepted, so an automatic retry is unsafe.
            if acceptedRecoverySaved, let receipt = activeTurnRecovery,
               settleAcceptedReceipt(receipt) {
                // Durable queue removal (if any) and pending retirement succeeded.
            } else {
                // 服务端已受理，只是 receipt / 队列行没能结算掉。这里必须是
                // acceptedUnretired：写成 `.none` 就等于放行重发同一条消息。
                gate.pending = .acceptedUnretired
                syncUncertain()
                pauseQueueForRecovery()
                notice = "服务端已接收消息，但本地记录未能保存。请勿重发，稍后同步。"
            }
            settleAcceptedAttachments(attachments.map(\.path))
            pendingAbsent = false
            flush()
            streamID = active

            guard generation == revision else {
                transition(to: .idle)
                // Session was switched while POST was in flight. Only
                // reconcile its result; do not attach an old stream to a new UI.
                let shouldResume = resumeRequested || !suspended
                resumeRequested = false
                if shouldResume { await load(silent: true, preserveLoadedOlder: true) }
                else { transition(to: .streaming(connected: false)) }
                return SubmitResult(accepted: true, completed: true)
            }
            resumeRequested = false
            transition(to: .streaming(connected: false))
            attach(streamID: active)
            return SubmitResult(accepted: true, completed: true)
        } catch {
            // POST 失败时页面可能已经切走/刷新：失配就只做本地收尾，
            // 不把旧请求的 error/draft/notice 写回新会话的状态。
            guard !runtimeRetired else { return SubmitResult(accepted: false, completed: true) }
            guard generation == revision else {
                // A different phase or submission must never be reset by an
                // old failure. The durable pending record stays fail-closed.
                if phase == .submitting && pendingSend?.id == pendingID {
                    transition(to: .idle)
                }
                return SubmitResult(accepted: false, completed: true)
            }
            self.error = error.localizedDescription
            recordRuntimeLog(.error, "send", "post fail err=\(error.localizedDescription)")
            // POST 结果不明：退回静止态，用 pending 锁住发送。
            // 不保留 `.submitting`——那会让界面永远停在「正在发送…」。
            //
            // 这里只写 `pending`，不写 `historyFresh`：错误的类型看起来像「读失败」，
            // 但它断言的是「服务端可能已经执行了这轮工具调用」。按错误类型归到历史
            // 新鲜度会立刻放开 canSend，用户重发即重复执行。
            // 明确被拒（400/401）暂不单独分流：`SendGate` 里没有「被拒」这一值，
            // 而 401 不能证明这次 POST 没被受理（见 handleAuthenticationFailure），
            // 409 更是服务端已换会话、POST 其实已生效。宁可多锁一次会话，
            // 也不在这里引入任何可重发路径。
            transition(to: .idle)
            gate.pending = .awaitingDecision
            syncUncertain()
            setDelivery(.unconfirmed, for:pendingID)
            flush()
            // 供用户直接重发：不覆盖等待期间新输入的内容。
            if draft.isEmpty, let originalDraft {
                if let store = draftStore {
                    let current = store.loadDraftResult()
                    if current.result.succeeded && current.value.isEmpty { draft = originalDraft }
                } else { draft = originalDraft }
            }
            if handleAuthenticationFailure(error) {
                return SubmitResult(accepted: false, completed: true)
            }
            notice = "暂时无法确认消息是否送达，草稿和附件已保留，正在自动同步。"
            scheduleAutomaticReconciliation()
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
        guard !runtimeRetired, !stopping, !loading, !syncing, !reconciling, !submitting else { return .failed }
        // 核对期间必须置位：视图的 pendingBusy 读它来禁用「核对/重发/放弃」。
        // silent 刷新不会设 loading，不置这个标志时三个按钮看起来都可用，
        // 连点会并发发起多个 GET。
        // 核对不是相位，而是与相位正交的事实：这次 GET 自己会走 `.syncing`，
        // 「核对中」与「同步中」必须同时成立。
        reconciling = true
        pendingAbsent = false
        // 核对窗口（可能跨多次 await）内禁止并发发送：这里绝不能只记历史新鲜度，
        // 否则用户或自动 flush 会把同一笔尚未结算的 POST 再发一次。
        gate.pending = .reconciling
        syncUncertain()
        // 同 prepareQueuedTurnForRetry：窗口关闭时必须结清。
        // `reconcilePending` 有多条提前 return（`pendingSend == nil`、
        // `pendingAbsent`、`pendingDeliveryIsVerified`），它们都不会走到末尾的
        // 赋值点，`applySnapshot` 又特意不清 `.reconciling`。
        defer {
            reconciling = false
            if gate.pending == .reconciling {
                gate.pending = .none
                syncUncertain()
            }
        }
        latestRecoverySnapshot = nil
        // A-07：这个 GET 归核对流程所有，必须允许在 reconciling 置位期间执行，
        // 且不能再让 refresh() 把标志抹掉（resetReconciling: false）。
        await refresh(silent: true, preserveLoadedOlder: true, resetReconciling: false)
        guard !Task.isCancelled, error == nil else { return .failed }
        if pendingSend == nil { return .delivered }
        guard pendingSend?.id == pending.id else { return .failed }
        if pendingAbsent { return .absent }
        if pendingDeliveryIsVerified {
            notice = "历史已确认消息送达；请在服务端确认任务结束后恢复原会话。"
            return .failed
        }

        // If the latest page does not cover the pre-POST boundary, read back
        // through contiguous raw history indexes. These GETs never send a turn.
        guard let historyEnd = pending.historyEnd,
              let latest = latestRecoverySnapshot,
              latest.sessionID == sessionID, !latest.readOnly,
              latest.activeRunEvidence == .absent,
              latest.olderOffset > historyEnd else { return .failed }
        let generation = revision
        if pendingHistoryWalk?.ownerID != pending.id ||
            pendingHistoryWalk?.boundary != historyEnd ||
            pendingHistoryWalk?.knownIDs != pending.knownIDs ||
            pendingHistoryWalk?.text != pending.text ||
            pendingHistoryWalk?.attachmentPaths != Set(pending.attachments.map(\.path)) ||
            pendingHistoryWalk?.matchesHead(latest) != true {
            pendingHistoryWalk = RecoveryHistoryWalk(ownerID: pending.id, boundary: historyEnd,
                knownIDs: pending.knownIDs, text: pending.text,
                attachmentPaths: Set(pending.attachments.map(\.path)), head: latest)
        }
        guard var walk = pendingHistoryWalk else { return .failed }
        for _ in 0..<max(1, recoveryPagesPerPass) where !walk.complete {
            guard !Task.isCancelled, generation == revision,
                  pendingSend?.id == pending.id, !suspended else { return .failed }
            let cursor = walk.cursor
            do {
                let older = try await recoveryHistory(sessionID: sessionID, before: cursor)
                guard generation == revision, pendingSend?.id == pending.id,
                      !Task.isCancelled, !suspended,
                      older.sessionID == sessionID, !older.readOnly,
                      older.activeRunEvidence == .absent,
                      older.rawMessageEndIndex == cursor,
                      older.olderOffset < cursor else { pendingHistoryWalk = nil; return .failed }
                guard walk.append(older) else { pendingHistoryWalk = nil; return .failed }
                pendingHistoryWalk = walk
            } catch {
                if handleAuthenticationFailure(error) { return .failed }
                if HistoryLoadFailure.classify(error) != .transient { pendingHistoryWalk = nil }
                notice = "较早的消息暂时无法同步，已保留发送记录，不会自动重发。"
                return .failed
            }
        }
        guard walk.complete else { return .failed }
        let rawDecision: PendingReconcileResult = walk.provesPendingDelivery ? .delivered :
            (walk.provesPendingAbsence ? .absent : .failed)
        guard rawDecision != .failed else { return .failed }
        if pending.submissionKey != nil && rawDecision == .absent { return .failed }
        let decision = rawDecision
        do {
            let current = try await recoveryHistory(sessionID: sessionID, before: nil)
            guard generation == revision, pendingSend?.id == pending.id,
                  !Task.isCancelled, !suspended,
                  current.sessionID == sessionID, !current.readOnly,
                  current.activeRunEvidence == .absent,
                  walk.matchesHead(current) else {
                pendingHistoryWalk = nil
                notice = "同步期间消息发生变化，已保留原消息，请稍后重试。"
                return .failed
            }
        } catch {
            if handleAuthenticationFailure(error) { return .failed }
            return .failed
        }
        if pending.submissionKey != nil {
            // A durable keyed admission with a lost response still lacks a
            // Run identity. Keep delivery proof separate from execution.
            notice = "历史已确认消息送达；请在服务端确认任务结束后恢复原会话。"
            return .failed
        }
        pendingHistoryWalk = nil
        if decision == .delivered {
            guard acknowledgeDeliveredQueuedTurn(matching: pending) else {
                // 历史已证实送达，只是队列行删不掉（写失败 / key 不匹配）。
                // 这不是「投递未知」，但同样不能放行：行还在，重试会再 POST。
                gate.pending = .acceptedUnretired
                syncUncertain()
                return .failed
            }
            guard clearPendingSend(expectedID: pending.id) else { return .failed }
            buffer.messages.removeAll { $0.id == pending.id }
            settleAcceptedAttachments(pending.attachments.map(\.path))
            if pending.queuedTurnID == nil { clearOriginalDraft(pending.composerText) }
            notice = "已从完整历史确认消息送达；没有重新提交。"
            gate.pending = .none
            syncUncertain()
            pendingAbsent = false
        } else {
            // A proven absence enables only explicit user choice, never POST.
            pendingAbsent = true
            // 全文件唯一「服务端权威证明这条没送到」的地方：只有这个状态允许重发。
            gate.pending = .absent
            syncUncertain()
            notice = "未找到这条消息，可自行决定是否重试。"
        }
        flush()
        return decision
    }

    /// 仅在核对确认后台不存在（`.absent`）后重发，附件原样带回（服务端引用，不重新上传）。
    func resendPending() async -> Bool {
        guard canResendPending, let pending = pendingSend else { return false }
        if let id = pending.queuedTurnID {
            guard queuedTurns.contains(where: { $0.id == id }) else {
                error = "原队列消息已变化，请在恢复中心同步后处理。"
                return false
            }
            return await dispatchSelectedQueuedTurn(id: id)
        }
        guard clearPendingSend(expectedID: pending.id) else { return false }
        buffer.messages.removeAll { $0.id == pending.id }
        // 证据已清：这一刻起没有未结算的 POST（随即 submit 会重新写 pending）。
        gate.pending = .none
        syncUncertain()
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
        let stillUncertain = !pendingAbsent
        if !stillUncertain {
            guard clearPendingSend(expectedID: pending.id) else { return }
        }
        ChatAttachmentPlaceholderStore.shared.forgetLocal(
            scope: displayScope, sessionID: sessionID, id: pending.id)
        buffer.messages.removeAll { $0.id == pending.id }
        // 放弃时若核对还没证明后台不存在，锁必须留在 `pending` 上：此时
        // `pendingSend` 被标记 hidden 但仍藏着证据，界面看起来 idle + 空队列，
        // 解锁就等于允许重发一条可能已在服务端执行的消息。
        let retainedPending: SendGate.PendingState = stillUncertain ? .awaitingDecision : .none
        gate.pending = retainedPending
        syncUncertain()
        pendingAbsent = false
        if stillUncertain {
            var retained = pending
            retained.hiddenFromTranscript = true
            pendingSend = retained
        }
        // 原文回填只填空输入框，不覆盖等待期间的新输入；附件占位不是用户文本。
        if restoreDraft, pending.queuedTurnID == nil,
           draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !pending.composerText.isEmpty {
            draft = pending.composerText
        }
        notice = stillUncertain ? "已隐藏本地未确认消息，暂不能确认是否送达，请同步后再发送。" : nil
        flush()
    }

    private func setDelivery(_ delivery: ChatDeliveryState, for id: String) {
        guard let index = buffer.messages.firstIndex(where: { $0.id == id }) else { return }
        buffer.messages[index].delivery = delivery
    }

}
