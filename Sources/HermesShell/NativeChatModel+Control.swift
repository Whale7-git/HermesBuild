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
            let outcome = try await api.approveNativeTurn(runID: pending.runID,
                                                          choice: choice,
                                                          requestID: pending.requestID)
            noteRunRecoveryState()
            guard generation == revision, !suspended,
                  pendingApprovals.contains(pending), !Task.isCancelled else { return }
            switch outcome {
            case nil:
                removePendingApproval(id: pending.id)
                notice = nil
                RuntimeLogRecorder.shared.record(.info, "approval", "choice=\(choice) accepted")
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
            RuntimeLogRecorder.shared.record(.error, "approval",
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
                RuntimeLogRecorder.shared.record(.info, "clarify", "answered chars=\(text.count)")
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
            RuntimeLogRecorder.shared.record(.error, "clarify",
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
        // STOP is an explicit cancellation boundary: preserve any user pause
        // and prohibit ordinary terminal-event queue dispatch from now on.
        pauseQueueForRecovery()
        transition(to: .stopping)
        do {
            try await api.stopNativeTurn(streamID: active)
            noteRunRecoveryState()
            guard generation == revision, streamID == active, !Task.isCancelled else { return }
            stopAcknowledged = true
            notice = "停止请求已受理，正在核对后台任务是否真正结束。"
            await verifyPendingStop()
            if stopping { scheduleStopStatusPolling() }
        } catch {
            guard generation == revision, streamID == active else { return }
            if handleAuthenticationFailure(error) { return }
            self.error = error.localizedDescription
            uncertain = true
            pauseQueueForRecovery()
            notice = "停止请求结果未确认；本轮发送仍锁定，请核对后台状态。"
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
            let result = try await api.probeActiveRun(sessionID: sessionID, runID: active)
            guard accepts(context), stopping, !Task.isCancelled else { return }
            switch result {
            case .alive:
                notice = "停止请求已受理，后台任务尚未结束；发送仍保持锁定。"
            case .unknown:
                notice = "停止请求已受理，暂时无法确认后台终态；发送仍保持锁定。"
            case .terminal(let outcome):
                let finalHistory = try await api.history(sessionID: sessionID, before: nil)
                guard accepts(context), stopping, !Task.isCancelled else { return }
                guard finalHistory.sessionID == sessionID,
                      finalHistory.activeStreamID == nil, !finalHistory.readOnly else {
                    uncertain = true
                    pauseQueueForRecovery()
                    notice = "后台已结束，但最终历史尚未确认；请稍后核对。"
                    return
                }
                stopStatusPollTask?.cancel()
                stopStatusPollTask = nil
                stopStatusPollTicket = nil
                stopAcknowledged = false
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
                if activeTurnRecovery?.runID == active {
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

    /// Only a few status GETs are permitted after an acknowledged STOP.
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
        RuntimeLogRecorder.shared.record(.error, "auth", "session expired err=\(error.localizedDescription)")
        revision &+= 1
        publishTask?.cancel()
        publishTask = nil
        streamTask?.cancel()
        streamTask = nil
        stopStatusPollTask?.cancel()
        stopStatusPollTask = nil
        stopStatusPollTicket = nil
        stopAcknowledged = false
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
