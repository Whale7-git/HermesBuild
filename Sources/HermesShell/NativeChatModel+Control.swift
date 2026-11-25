import Foundation

extension NativeChatModel {
    /// Upsert one server request without disturbing sibling requests from the
    /// same run. Returns true only when this identity was newly inserted.
    @discardableResult
    func upsertPendingApproval(_ pending: ChatPendingApproval) -> Bool {
        if let index = pendingApprovals.firstIndex(where: { $0.id == pending.id }) {
            if pendingApprovals[index] != pending { pendingApprovals[index] = pending }
            return false
        }
        pendingApprovals.append(pending)
        return true
    }

    @discardableResult
    func upsertPendingClarify(_ pending: ChatPendingClarify) -> Bool {
        if let index = pendingClarifies.firstIndex(where: { $0.id == pending.id }) {
            if pendingClarifies[index] != pending { pendingClarifies[index] = pending }
            return false
        }
        pendingClarifies.append(pending)
        return true
    }

    func removePendingApproval(id: String) {
        guard let index = pendingApprovals.firstIndex(where: { $0.id == id }) else { return }
        let removed = pendingApprovals.remove(at: index)
        onApprovalResolved?(sessionID, removed.requestID)
        if pendingApprovals.isEmpty { approving = false }
    }

    func removePendingClarify(id: String) {
        guard let index = pendingClarifies.firstIndex(where: { $0.id == id }) else { return }
        let removed = pendingClarifies.remove(at: index)
        onClarifyResolved?(sessionID, removed.requestID)
        if pendingClarifies.isEmpty { clarifying = false }
    }

    func removePendingApprovals(for runID: String?) {
        // An authoritative snapshot names the run that is still alive. Requests
        // from any other run are stale; a nil active run invalidates all cards.
        let removed = pendingApprovals.filter { $0.runID != runID }
        guard !removed.isEmpty else { return }
        pendingApprovals.removeAll { $0.runID != runID }
        for request in removed { onApprovalResolved?(sessionID, request.requestID) }
        if pendingApprovals.isEmpty { approving = false }
    }

    func removePendingApproval(requestID: String, runID: String) {
        guard let pending = pendingApprovals.first(where: {
            $0.requestID == requestID && $0.runID == runID
        }) else { return }
        removePendingApproval(id: pending.id)
    }

    func removePendingClarifies(for runID: String?) {
        let removed = pendingClarifies.filter { $0.runID != runID }
        guard !removed.isEmpty else { return }
        pendingClarifies.removeAll { $0.runID != runID }
        for request in removed { onClarifyResolved?(sessionID, request.requestID) }
        if pendingClarifies.isEmpty { clarifying = false }
    }

    /// Replace only the controls for the exact active Run. This is used when
    /// a Gateway status snapshot explicitly supplies its current pending set.
    /// Missing capability is represented by nil and never clears known cards.
    func restorePendingControls(_ snapshot: GatewayPendingControlSnapshot, runID: String) {
        // Parse before mutating. A partial projection cannot revoke a card
        // that remains actionable on the same Run, nor silently resume a queue.
        var nextApprovals: [ChatPendingApproval] = []
        var nextClarifies: [ChatPendingClarify] = []
        var incomplete = snapshot.hasIncompleteControl
        for frame in snapshot.frames {
            switch frame.event {
            case "approval":
                guard let pending = ChatPendingApproval.make(from: frame, runID: runID),
                      pending.runID == runID, pending.requestID != nil else {
                    incomplete = true
                    continue
                }
                nextApprovals.append(pending)
            case "clarify":
                guard let pending = ChatPendingClarify.make(from: frame, runID: runID),
                      pending.runID == runID else {
                    incomplete = true
                    continue
                }
                nextClarifies.append(pending)
            default:
                incomplete = true
            }
        }

        if incomplete {
            for pending in nextApprovals { _ = upsertPendingApproval(pending) }
            for pending in nextClarifies { _ = upsertPendingClarify(pending) }
            uncertain = true
            pauseQueueForRecovery()
            notice = "后台仍有待处理审批或澄清，但快照数据不完整；已保留原卡片并锁定发送。"
            return
        }

        let oldApprovals = pendingApprovals.filter { $0.runID == runID }
        let oldClarifies = pendingClarifies.filter { $0.runID == runID }
        pendingApprovals.removeAll { $0.runID == runID }
        pendingClarifies.removeAll { $0.runID == runID }
        for pending in nextApprovals { _ = upsertPendingApproval(pending) }
        for pending in nextClarifies { _ = upsertPendingClarify(pending) }

        let approvalIDs = Set(nextApprovals.map(\.id))
        let clarifyIDs = Set(nextClarifies.map(\.id))
        for request in oldApprovals where !approvalIDs.contains(request.id) {
            onApprovalResolved?(sessionID, request.requestID)
        }
        for request in oldClarifies where !clarifyIDs.contains(request.id) {
            onClarifyResolved?(sessionID, request.requestID)
        }
        if pendingApprovals.isEmpty { approving = false }
        if pendingClarifies.isEmpty { clarifying = false }
        // Only an independent, fully verified Run/POST reconciliation may
        // clear queueRecoveryPaused. The control projection never authorizes it.
    }

    func removePendingClarify(requestID: String) {
        guard let pending = pendingClarifies.first(where: { $0.requestID == requestID }) else { return }
        removePendingClarify(id: pending.id)
    }

    /// User answers may complete out of order. While one POST is in flight the
    /// UI disables every request, so selecting another card must not silently
    /// fall back to the newest slot and answer the wrong server prompt.
    func canRespondToApproval(requestID: String, choice: String) -> Bool {
        guard let pending = pendingApprovals.first(where: { $0.id == requestID }) else {
            return false
        }
        return !approving && !suspended && pending.choices.contains(choice)
            && streamID == pending.runID && !pending.runID.isEmpty
    }

    func canRespondToClarify(requestID: String) -> Bool {
        guard let pending = pendingClarifies.first(where: { $0.id == requestID }) else {
            return false
        }
        return !clarifying && !suspended && streamID == pending.runID
            && !pending.runID.isEmpty
    }

    /// 回传一次审批决定。
    ///
    /// 成功就撤卡片，让流继续往下跑——网关在收到答复前不会推进本轮。
    /// 失败分三类处理：服务端说这张票已失效（not_pending）就撤掉并说明；
    /// 说选项不合法（rejected）说明是版本不匹配；网络错误保留卡片让用户重试。
    func respondToApproval(_ choice: String, requestID: String? = nil) async {
        let target = requestID.flatMap { id in pendingApprovals.first { $0.id == id } }
            ?? pendingApproval
        guard let pending = target, !approving, !suspended,
              pending.choices.contains(choice), streamID == pending.runID else { return }
        // runID 必须已知：没有它连往哪儿发都不知道，宁可不发也不猜。
        guard !pending.runID.isEmpty else {
            notice = "无法确定这条审批所属的轮次，请刷新会话后重试。"
            return
        }
        approving = true
        let generation = revision
        let submission = UUID()
        approvalSubmission = submission
        defer { if approvalSubmission == submission { approving = false } }
        do {
            guard let requestID = pending.requestID else { return }
            let outcome = try await api.approveNativeTurn(
                runID: pending.runID, choice: choice, requestID: requestID,
                executionGeneration: pending.executionGeneration)
            noteRunRecoveryState()
            guard generation == revision, !suspended,
                  pendingApprovals.contains(pending), !Task.isCancelled else { return }
            switch outcome {
            case nil:
                removePendingApproval(id: pending.id)
                notice = nil
                recordRuntimeLog(.info, "approval", "choice=\(choice) accepted")
            case "unsupported":
                removePendingApproval(id: pending.id)
                notice = "当前后端不支持在 App 内审批，请在 WebUI 处理。"
            case "not_pending":
                removePendingApproval(id: pending.id)
                notice = "这条审批已经失效（超时或被别处处理），稍后会同步最新状态。"
            case let other?:
                removePendingApproval(id: pending.id)
                notice = "服务端拒绝了这次审批（\(other)）。"
            }
        } catch {
            guard generation == revision, !suspended,
                  pendingApprovals.contains(pending), !Task.isCancelled else { return }
            if handleAuthenticationFailure(error) { return }
            self.error = error.localizedDescription
            recordRuntimeLog(.error, "approval",
                                             "choice=\(choice) failed err=\(error.localizedDescription)")
        }
    }

    func clearApproval() {
        let removed = pendingApprovals
        pendingApprovals = []
        for request in removed { onApprovalResolved?(sessionID, request.requestID) }
        approvalSubmission = UUID()
        approving = false
    }

    /// 回传一次补充信息答复。
    ///
    /// `answer` 传原始文本（用户输入的，或点选的选项文字）——**不做任何本地解析**。
    /// 服务端 `_coerce_text_response` 认编号、认标签、认 `1,3` 多选，也负责把
    /// 「有选项时用户直接说了一句话」判成 prose 并取消这次 clarify；客户端若自己
    /// 先映射一遍，会与服务端口径不一致，答错选项。
    ///
    /// 失败分类与审批一致：`not_pending` 撤卡片并说明；`rejected` 说明合同不匹配
    /// （多半是 generation 过期）；网络错误保留卡片让用户重试。
    func respondToClarify(_ answer: String, requestID: String? = nil) async {
        let target = requestID.flatMap { id in pendingClarifies.first { $0.id == id } }
            ?? pendingClarify
        guard let pending = target, !clarifying, !suspended,
              streamID == pending.runID else { return }
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        // 开放式提问允许任意文本，但空串没有意义：服务端会当成空答案。
        guard !text.isEmpty else {
            notice = "请先填写或选择一项再提交。"
            return
        }
        // runID 必须已知：没有它连往哪儿发都不知道。
        guard !pending.runID.isEmpty else {
            notice = "无法确定这条提问所属的轮次，请刷新会话后重试。"
            return
        }
        clarifying = true
        let generation = revision
        let submission = UUID()
        clarifySubmission = submission
        defer { if clarifySubmission == submission { clarifying = false } }
        do {
            let outcome = try await api.clarifyNativeTurn(
                runID: pending.runID, answer: text,
                requestID: pending.requestID,
                executionGeneration: pending.executionGeneration)
            noteRunRecoveryState()
            guard generation == revision, !suspended,
                  pendingClarifies.contains(pending), !Task.isCancelled else { return }
            switch outcome {
            case nil:
                removePendingClarify(id: pending.id)
                notice = nil
                recordRuntimeLog(.info, "clarify", "answered chars=\(text.count)")
            case "unsupported":
                removePendingClarify(id: pending.id)
                notice = "当前后端不支持在 App 内回答补充信息，请在 WebUI 处理。"
            case "not_pending":
                removePendingClarify(id: pending.id)
                notice = "这条提问已经失效（超时或被别处处理），稍后会同步最新状态。"
            case let other?:
                removePendingClarify(id: pending.id)
                notice = "服务端拒绝了这次回答（\(other)）。"
            }
        } catch {
            guard generation == revision, !suspended,
                  pendingClarifies.contains(pending), !Task.isCancelled else { return }
            if handleAuthenticationFailure(error) { return }
            self.error = error.localizedDescription
            recordRuntimeLog(.error, "clarify",
                                             "answer failed err=\(error.localizedDescription)")
        }
    }

    func clearClarify() {
        let removed = pendingClarifies
        pendingClarifies = []
        for request in removed { onClarifyResolved?(sessionID, request.requestID) }
        clarifySubmission = UUID()
        clarifying = false
    }

    /// A stop POST is an acknowledgement, not proof that the run has ended.
    /// Keep the stream attached and ordinary sending disabled until the exact
    /// run reaches a verified terminal status and the final history GET succeeds.
    func stop() async {
        guard let active = streamID, !stopping, !submitting else { return }
        let generation = revision
        stopAcknowledged = false
        stopRejectedStatusCode = nil
        // STOP is an explicit cancellation boundary: preserve any user pause
        // and prohibit ordinary terminal-event queue dispatch from now on.
        pauseQueueForRecovery()
        transition(to: .stopping)
        do {
            try await api.stopNativeTurn(streamID: active)
            noteRunRecoveryState()
            guard generation == revision, streamID == active, !Task.isCancelled else { return }
            stopAcknowledged = true
            stopRejectedStatusCode = nil
            notice = "停止请求已受理，正在核对后台任务是否真正结束。"
            await verifyPendingStop()
            if stopping { scheduleStopStatusPolling() }
        } catch {
            guard generation == revision, streamID == active else { return }
            if handleAuthenticationFailure(error) { return }
            self.error = error.localizedDescription
            uncertain = true
            pauseQueueForRecovery()
            if let stopError = error as? ChatStopHTTPError,
               case .rejected(let code) = stopError {
                stopRejectedStatusCode = code
                notice = "停止请求被服务端拒绝（HTTP \(code)）；正在核对原 Run，发送保持锁定。"
            } else {
                stopRejectedStatusCode = nil
                notice = "停止请求结果未知；正在核对原 Run，发送保持锁定。"
            }
            // A failed/unknown STOP response is not terminal evidence. Perform
            // a fresh GET-only check, then continue the bounded poll if needed.
            await verifyPendingStop()
            if stopping { scheduleStopStatusPolling() }
        }
    }

    /// Read-only verification, safe to invoke again from the visible notice.
    /// Neither the status GET nor the history GET can replay the original POST.
    func verifyPendingStop() async {
        guard stopping, let active = streamID, !stopStatusProbeInFlight else { return }
        stopStatusProbeInFlight = true
        defer { stopStatusProbeInFlight = false }
        let generation = revision
        let context = runContext(for: active, generation: generation)
        do {
            let result: ActiveRunProbe
            if let receipt = activeTurnRecovery, receipt.runID == active,
               let terminal = receipt.terminalStatus { result = .terminal(terminal) }
            else { result = try await recoveryProbe(sessionID: sessionID, runID: active) }
            guard accepts(context), stopping, !Task.isCancelled else { return }
            switch result {
            case .alive:
                if stopAcknowledged {
                    notice = "停止请求已受理，后台任务尚未结束；发送仍保持锁定。"
                } else if let code = stopRejectedStatusCode {
                    notice = "停止请求被服务端拒绝（HTTP \(code)），原任务仍运行；发送保持锁定。"
                } else {
                    notice = "停止请求结果未知，原任务仍运行；发送保持锁定。"
                }
            case .unknown:
                if stopAcknowledged {
                    notice = "停止请求已受理，暂时无法确认后台终态；发送仍保持锁定。"
                } else if let code = stopRejectedStatusCode {
                    notice = "停止请求被服务端拒绝（HTTP \(code)），后台状态仍未知；发送保持锁定。"
                } else {
                    notice = "停止请求结果未知，后台状态仍未知；发送保持锁定。"
                }
            case .unresolved:
                uncertain = true
                pauseQueueForRecovery()
                streamID = nil
                stopAcknowledged = false
                transition(to: .idle)
                notice = "后台未找到原任务；已停止本地运行指示，原发送结果仍待核对。"
            case .terminal(let outcome):
                guard rememberTerminalStatus(runID: active, outcome: outcome) else {
                    uncertain = true
                    pauseQueueForRecovery()
                    return
                }
                let finalHistory = try await recoveryHistory(sessionID: sessionID, before: nil)
                guard accepts(context), stopping, !Task.isCancelled else { return }
                guard finalHistory.sessionID == sessionID,
                      finalHistory.activeRunEvidence == .absent, !finalHistory.readOnly else {
                    uncertain = true
                    pauseQueueForRecovery()
                    notice = "后台已结束，但最终历史尚未确认；请稍后核对。"
                    return
                }
                stopStatusPollTask?.cancel()
                stopStatusPollTask = nil
                stopStatusPollTicket = nil
                stopAcknowledged = false
                stopRejectedStatusCode = nil
                revision &+= 1
                streamTask?.cancel()
                streamTask = nil
                streamID = nil
                clearApproval()
                clearClarify()
                if outcome == .cancelled || outcome == .interrupted {
                    buffer.appendStopNotice()
                }
                try applySnapshot(finalHistory, preserveLoadedOlder: true)
                if let receipt = activeTurnRecovery, receipt.runID == active {
                    if !RunFinalizer.canSettle([finalHistory], sessionID: sessionID,
                        runID: active, receipt: receipt, outcome: outcome, requireReply: true) {
                        uncertain = true
                        pauseQueueForRecovery()
                        notice = "任务已结束，最终回复仍在同步。"
                        scheduleAutomaticReconciliation()
                        return
                    }
                    guard clearAcceptedTurnRecovery() else { return }
                    uncertain = pendingSend != nil || pendingRecoveryUnreadable
                        || activeRecoveryUnreadable
                }
                pauseQueueForRecovery()
                notice = outcome.notice
            }
        } catch {
            guard accepts(context), stopping else { return }
            if handleAuthenticationFailure(error) { return }
            self.error = error.localizedDescription
            uncertain = true
            pauseQueueForRecovery()
            notice = "停止请求已受理，但终态或历史同步失败；不会重复提交消息。"
        }
    }

    /// Only a few status GETs are permitted after an attempted STOP.
    /// A still-running/unknown run stays locked; polling never changes queue
    /// preferences or grants permission to dispatch the next turn.
    func scheduleStopStatusPolling() {
        guard stopStatusPollTask == nil, stopping, let active = streamID,
              !suspended else { return }
        let generation = revision
        let ticket = UUID()
        stopStatusPollTicket = ticket
        let delays = stopStatusPollDelaysNanoseconds
        stopStatusPollTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.stopStatusPollTicket == ticket {
                    self.stopStatusPollTask = nil
                    self.stopStatusPollTicket = nil
                }
            }
            for delay in delays {
                do { try await Task.sleep(nanoseconds: delay) }
                catch { return }
                guard !Task.isCancelled, generation == self.revision,
                      self.streamID == active, self.stopping, !self.suspended else { return }
                await self.verifyPendingStop()
                guard !Task.isCancelled, generation == self.revision,
                      self.streamID == active, self.stopping, !self.suspended else { return }
            }
            if generation == self.revision, self.streamID == active, self.stopping {
                self.notice = "停止状态暂未得到服务端确认；不会再次发送停止或聊天请求。返回会话时将自动继续核对。"
            }
        }
    }

    /// Authentication failures retire the view's account namespace in AppState.
    /// Do not leave another account's cached text visible behind a login sheet,
    /// and do not spend the reconnect budget on an unauthenticated stream.
    @discardableResult func handleAuthenticationFailure(_ error: Error) -> Bool {
        guard api.requiresAuthentication(after: error) else { return false }
        recordRuntimeLog(.error, "auth", "session expired err=\(error.localizedDescription)")
        revision &+= 1
        publishTask?.cancel()
        publishTask = nil
        streamTask?.cancel()
        streamTask = nil
        stopStatusPollTask?.cancel()
        stopStatusPollTask = nil
        stopStatusPollTicket = nil
        stopAcknowledged = false
        stopRejectedStatusCode = nil
        buffer = ChatTranscript()
        confirmedHistory = nil
        confirmedHistoryEnd = nil
        settledAttachmentPaths = []
        lastEventID = nil
        streamID = nil
        olderOffset = 0
        sessionModel = nil
        sessionProvider = nil
        suspended = false
        // 登录失效是相位本身，不是叠加在相位上的事实：直接落 `.needsLogin`。
        transition(to: .needsLogin)
        readOnly = true
        uncertain = true
        // 换账号后既不能保留上一账号的待核对正文，也不能凭它的附件引用重发。
        pendingSend = nil
        queuedTurns = []
        queueUserPaused = false
        queueRecoveryPaused = false
        updateQueuePause()
        queueSaveFailed = false
        let clearResult = draftStore?.saveQueued(nil)
        if let clearResult, !clearResult.succeeded {
            recordLocalWrite(clearResult, kind: .queue)
        } else if localPersistenceIssue?.kind == .queue {
            localPersistenceIssue = nil
        }
        clearApproval()
        clearClarify()
        pendingAbsent = false
        self.error = error.localizedDescription
        notice = "登录状态已失效，请重新登录后读取历史。"
        flush()
        if !authenticationReported {
            authenticationReported = true
            onAuthenticationRequired?()
        }
        return true
    }

}
